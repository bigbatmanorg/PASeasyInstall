# Installer media identification by file name. Pure PowerShell (5.1 + 7), read-only:
# folders are walked, and ZIP files are inspected through their central directory only
# (nothing is extracted, so a 5 GB bundle is classified instantly).
# These are the private helpers of the public commands Get-PASMediaInventory and Get-PASMediaSelection
# (Public folder): the classification table, version/variant parsing and the ZIP reader.

$script:PASMediaRules = @(
    # Component, regex on the file/entry base name. First match wins; order matters.
    @{
        C = 'Ignore'
        R = '(?i)ansible|upgrade|add-ons|docs|documentation|replicate|exportvaultdata|remote control|signed dna|self-hosted_on'
    }
    @{C = 'Vault'; R = '(?i)^server-rls-v' }
    @{C = 'PACLI'; R = '(?i)^pacli-rls-v' }
    @{C = 'DR'; R = '(?i)^disaster recovery-rls-v' }
    @{C = 'KeyGen'; R = '(?i)^pa key gen-rls-v' }
    @{C = 'PVWA'; R = '(?i)^(password vault web access|pvwa)-rls-v' }
    @{C = 'CPM'; R = '(?i)^(central policy manager|cpm)-rls-v' }
    @{C = 'PSM'; R = '(?i)^(privileged session manager|psm)-rls-v' }
    @{C = 'PSMP'; R = '(?i)^privilegedsessionmanagersshproxy-' }
    @{C = 'HTML5GW'; R = '(?i)^html5 gateway-rls-' }
    @{C = 'PTA'; R = '(?i)^pta-installer-rls-' }
    @{C = 'License'; R = '(?i)licen[cs]e.*\.xml$' }
    @{C = 'RecoveryKey'; R = '(?i)^recpub\.key$' }
    # Needed by the Vault install, found by the backend in the media folder; not a selectable installer.
    @{C = 'Prerequisite'; R = '(?i)^(vc_redist\.(x86|x64)|vcredist_x86(_2013)?)\.exe$' }
)
$script:PASMediaInstallable = @('Vault', 'PACLI', 'DR', 'KeyGen', 'PVWA', 'CPM', 'PSM', 'PSMP', 'HTML5GW', 'PTA', 'License', 'RecoveryKey')

function Get-PASMediaClassification {
    param([string]$Name)
    foreach ($rule in $script:PASMediaRules) { if ($Name -match $rule.R) { return $rule.C } }
    return 'Unknown'
}
function Get-PASMediaVersion {
    param([string]$Name)
    if ($Name -match '(?i)-rls-v?([0-9][0-9.]*[0-9])') { return $Matches[1] }
    if ($Name -match '(?i)v([0-9]+(\.[0-9]+)+)') { return $Matches[1] }
    return ''
}
function Get-PASMediaVariant {
    param([string]$Component, [string]$Name)
    if ($Component -eq 'PSMP' -and $Name -match '(?i)sshproxy-([A-Za-z0-9]+)-') { return $Matches[1] }
    return ''
}
function Test-PASZipTail {
    # $true when the ZIP end record ("PK" 05 06) is found in the last bytes of a file, or of a part of it
    # (-Offset, -Length: a package stored inside a bundle). A ZIP without it was cut off or damaged.
    param([string]$Path, [long]$Offset = 0, [long]$Length = -1)
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($Length -lt 0) {
            $Length = $stream.Length - $Offset
        }
        $count = [int][Math]::Min($Length, 66000)
        if ($count -lt 22) {
            return $false
        }
        $buffer = New-Object byte[] $count
        $stream.Position = $Offset + $Length - $count
        $read = 0
        while ($read -lt $count) {
            $got = $stream.Read($buffer, $read, $count - $read)
            if ($got -le 0) {
                break
            }
            $read += $got
        }
        for ($i = $read - 22; $i -ge 0; $i--) {
            if ($buffer[$i] -eq 0x50 -and $buffer[$i + 1] -eq 0x4B -and $buffer[$i + 2] -eq 0x05 -and $buffer[$i + 3] -eq 0x06) {
                return $true
            }
        }
        return $false
    } finally {
        $stream.Dispose()
    }
}
function Test-PASMediaDamaged {
    # $true when a package (a .zip file, or a .zip stored inside a bundle) is not a complete ZIP file.
    # What cannot be judged (a compressed entry, an unexpected .NET build) counts as not damaged: the
    # installation checks the package again when it unpacks it.
    param([string]$Path, [string]$Name, $Entry = $null)
    if ($Name -notmatch '(?i)\.zip$') {
        return $false
    }
    try {
        if ($null -eq $Entry) {
            return (-not (Test-PASZipTail -Path $Path))
        }
        if ($Entry.CompressedLength -ne $Entry.Length) {
            return $false
        }
        $property = $Entry.GetType().GetProperty('OffsetOfCompressedData', [Reflection.BindingFlags]'NonPublic,Instance')
        if (-not $property) {
            return $false
        }
        $offset = [long]$property.GetValue($Entry, $null)
        return (-not (Test-PASZipTail -Path $Path -Offset $offset -Length ([long]$Entry.Length)))
    } catch {
        return $false
    }
}
function New-PASMediaItem {
    param([string]$Path, [string]$Entry, [string]$Component, [string]$Name, [string]$Container, [bool]$Damaged = $false)
    if (-not $Entry -and -not $Damaged -and $Component -in $script:PASMediaInstallable -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $Damaged = Test-PASMediaDamaged -Path $Path -Name $Name
    }
    [pscustomobject]@{
        Component = $Component; Name = $Name; Version = (Get-PASMediaVersion $Name)
        Variant = (Get-PASMediaVariant $Component $Name)
        Path = $Path; Entry = $Entry   # Entry: path inside a ZIP bundle, '' for a plain file
        Source = $(if ($Entry) { [IO.Path]::GetFileName($Path) + ' › ' + $Entry } else { $Path })
        Container = $Container
        # $true: the package is not a complete ZIP file (cut off or damaged). It is never chosen when
        # another copy of the component is there.
        Damaged = $Damaged
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
                    $damaged = Test-PASMediaDamaged -Path $Path -Name $entry.Name -Entry $entry
                    [void]$found.Add((New-PASMediaItem -Path $Path -Entry $entry.FullName -Component $kind -Name $entry.Name -Container 'Bundle' -Damaged $damaged))
                }
            }
        } finally { $zip.Dispose() }
    } catch { }
    return @($found.ToArray())
}
