# Installer media identification by file name. Pure PowerShell (5.1 + 7), read-only:
# folders are walked, and ZIP files are inspected through their central directory only
# (nothing is extracted, so a 5 GB bundle is classified instantly).
# These are the private helpers of the public commands Get-PASMediaInventory and Get-PASMediaSelection
# (Public folder): the classification table, version/variant parsing and the ZIP reader.

$script:PASMediaRules = @(
    # Component, regex on the file/entry base name. First match wins; order matters.
    @{
        C = 'Ignore'
        R = '(?i)ansible|upgrade|add-ons|docs|documentation|replicate|exportvaultdata|remote control|signed dna|self-hosted_on|html5 gateway'
    }
    @{C = 'Vault'; R = '(?i)^server-rls-v' }
    @{C = 'PACLI'; R = '(?i)^pacli-rls-v' }
    @{C = 'DR'; R = '(?i)^disaster recovery-rls-v' }
    @{C = 'KeyGen'; R = '(?i)^pa key gen-rls-v' }
    @{C = 'PVWA'; R = '(?i)^(password vault web access|pvwa)-rls-v' }
    @{C = 'CPM'; R = '(?i)^(central policy manager|cpm)-rls-v' }
    @{C = 'PSM'; R = '(?i)^(privileged session manager|psm)-rls-v' }
    @{C = 'PSMP'; R = '(?i)^privilegedsessionmanagersshproxy-' }
    @{C = 'License'; R = '(?i)licen[cs]e.*\.xml$' }
    @{C = 'RecoveryKey'; R = '(?i)^recpub\.key$' }
    # Needed by the Vault install, found by the backend in the media folder; not a selectable installer.
    @{C = 'Prerequisite'; R = '(?i)^(vc_redist\.(x86|x64)|vcredist_x86(_2013)?)\.exe$' }
)
$script:PASMediaInstallable = @('Vault', 'PACLI', 'DR', 'KeyGen', 'PVWA', 'CPM', 'PSM', 'PSMP', 'License', 'RecoveryKey')

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
