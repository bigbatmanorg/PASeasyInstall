# Installer media identification by file name. Pure PowerShell (5.1 + 7), read-only:
# folders are walked, and ZIP files are inspected through their central directory only
# (nothing is extracted, so a 5 GB bundle is classified instantly).
# One file, two identical copies: Modules/PASeasyInstall.Orchestrator/Private/MediaInventory.ps1 (real
# backend) and Modules/PASeasyInstall.UI/Backend/MediaInventory.ps1 (Mock). Tests keep them identical.

$script:PASMediaRules = @(
    # Component, regex on the file/entry base name. First match wins; order matters.
    @{C='Ignore';      R='(?i)ansible|upgrade|add-ons|docs|documentation|replicate|exportvaultdata|remote control|signed dna|self-hosted_on|html5 gateway'}
    @{C='Vault';       R='(?i)^server-rls-v'}
    @{C='PACLI';       R='(?i)^pacli-rls-v'}
    @{C='DR';          R='(?i)^disaster recovery-rls-v'}
    @{C='KeyGen';      R='(?i)^pa key gen-rls-v'}
    @{C='PVWA';        R='(?i)^(password vault web access|pvwa)-rls-v'}
    @{C='CPM';         R='(?i)^(central policy manager|cpm)-rls-v'}
    @{C='PSM';         R='(?i)^(privileged session manager|psm)-rls-v'}
    @{C='PSMP';        R='(?i)^privilegedsessionmanagersshproxy-'}
    @{C='PTA';         R='(?i)^pta-installer-rls-v'}
    @{C='License';     R='(?i)licen[cs]e.*\.xml$'}
    @{C='RecoveryKey'; R='(?i)^recpub\.key$'}
    # Needed by the Vault install, found by the backend in the media folder; not a selectable installer.
    @{C='Prerequisite'; R='(?i)^(vc_redist\.(x86|x64)|vcredist_x86(_2013)?)\.exe$'}
)
$script:PASMediaInstallable = @('Vault','PACLI','DR','KeyGen','PVWA','CPM','PSM','PSMP','License','RecoveryKey')

function Get-PASMediaClassification {
    param([string]$Name)
    foreach ($rule in $script:PASMediaRules) { if ($Name -match $rule.R) { return $rule.C } }
    return 'Unknown'
}
function Get-PASMediaVersion {
    param([string]$Name)
    if ($Name -match '(?i)-rls-v([0-9][0-9.]*[0-9])') { return $Matches[1] }
    if ($Name -match '(?i)v([0-9]+(\.[0-9]+)+)') { return $Matches[1] }
    return ''
}
function Get-PASMediaVariant {
    param([string]$Component, [string]$Name)
    if ($Component -eq 'PSMP' -and $Name -match '(?i)sshproxy-([A-Za-z0-9]+)-') { return $Matches[1] }
    return ''
}
function New-PASMediaItem {
    param([string]$Path, [string]$Entry, [string]$Component, [string]$Name, [string]$Container)
    [pscustomobject]@{
        Component = $Component; Name = $Name; Version = (Get-PASMediaVersion $Name)
        Variant = (Get-PASMediaVariant $Component $Name)
        Path = $Path; Entry = $Entry   # Entry: path inside a ZIP bundle, '' for a plain file
        Source = $(if ($Entry) { [IO.Path]::GetFileName($Path) + ' › ' + $Entry } else { $Path })
        Container = $Container
    }
}
function Get-PASZipMedia {
    param([string]$Path)
    $found = New-Object System.Collections.ArrayList
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($entry in $zip.Entries) {
                if (-not $entry.Name) { continue }   # directory entry
                $kind = Get-PASMediaClassification $entry.Name
                if ($kind -in $script:PASMediaInstallable) {
                    [void]$found.Add((New-PASMediaItem -Path $Path -Entry $entry.FullName -Component $kind -Name $entry.Name -Container 'Bundle'))
                }
            }
        } finally { $zip.Dispose() }
    } catch { }
    return @($found.ToArray())
}
function Get-PASMediaInventory {
    <#
    .SYNOPSIS
    Finds CyberArk installer media in files, folders and ZIP bundles (folders searched to depth 4). Read-only.
    .DESCRIPTION
    Detects components by file name, including inside the CyberArk bundle ZIP, which is read and never
    extracted. Returns items with Component, Name, Version, Variant, Path, Entry, Source and Container.
    Component is Vault, PACLI, DR, KeyGen, PVWA, CPM, PSM, PSMP, License, RecoveryKey, Prerequisite or Unknown.
    .EXAMPLE
    Get-PASMediaInventory -Path D:\CyberArkMedia | Format-Table Component,Version,Variant,Name
    #>
    [CmdletBinding()]param([Parameter(Mandatory)][string[]]$Path)
    $items = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    foreach ($p in $Path) { if ($p) { $queue.Enqueue(@{P=$p; D=0}) } }
    while ($queue.Count) {
        $next = $queue.Dequeue(); $p = [string]$next.P
        if (Test-Path -LiteralPath $p -PathType Container) {
            if ($next.D -ge 4) { continue }
            foreach ($child in @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                $queue.Enqueue(@{P=$child.FullName; D=$next.D + 1})
            }
            continue
        }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            [void]$items.Add((New-PASMediaItem -Path $p -Entry '' -Component 'Missing' -Name ([IO.Path]::GetFileName($p)) -Container 'File'))
            continue
        }
        $name = [IO.Path]::GetFileName($p)
        $kind = Get-PASMediaClassification $name
        if ($kind -eq 'Ignore') { continue }
        if ($kind -ne 'Unknown') {
            [void]$items.Add((New-PASMediaItem -Path $p -Entry '' -Component $kind -Name $name -Container 'File')); continue
        }
        if ($name -match '(?i)\.zip$') {
            $inner = @(Get-PASZipMedia -Path $p)
            if ($inner.Count) { foreach ($i in $inner) { [void]$items.Add($i) }; continue }
        }
        if ($name -match '(?i)\.(zip|xml|key|exe|msi|rpm|deb|tar|gz)$') {
            [void]$items.Add((New-PASMediaItem -Path $p -Entry '' -Component 'Unknown' -Name $name -Container 'File'))
        }
    }
    # The same installer as a plain file and inside a bundle is one choice, not two: keep the plain file.
    $plain = @{}
    foreach ($i in $items) { if (-not $i.Entry) { $plain[($i.Component + '|' + $i.Name).ToLowerInvariant()] = $true } }
    return @($items.ToArray() | Where-Object { -not $_.Entry -or -not $plain.ContainsKey(($_.Component + '|' + $_.Name).ToLowerInvariant()) })
}
function Get-PASMediaSelection {
    <#
    .SYNOPSIS
    Picks one installer per component from Get-PASMediaInventory output; returns @{ Component = item }.
    .DESCRIPTION
    Picks the highest version. PSMP prefers Ubuntu 24, then RHEL 9. At equal versions, a plain file beats the
    same installer inside a bundle, which would have to be extracted.
    .EXAMPLE
    $sel = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path D:\CyberArkMedia)
    #>
    param([object[]]$Inventory)
    $pick = @{}
    foreach ($group in @($Inventory | Where-Object { $_.Component -in $script:PASMediaInstallable } | Group-Object Component)) {
        $sorted = @($group.Group | Sort-Object -Descending -Property @{Expression={
            $rank = switch -Regex ($_.Variant) { '^Ubuntu24' {3} '^RHELinux9' {2} '^RHELinux8' {1} default {0} }
            if ($_.Component -eq 'License' -and $_.Name -notmatch '(?i)conjur') { $rank = 1 }   # plain PAM license first
            $rank}}, @{Expression={ try { [version]($_.Version -replace '^(\d+(\.\d+){0,3}).*$','$1') } catch { [version]'0.0' } }},
            @{Expression={ if ($_.Entry) { 0 } else { 1 } }})
        $pick[$group.Name] = $sorted[0]
    }
    return $pick
}
