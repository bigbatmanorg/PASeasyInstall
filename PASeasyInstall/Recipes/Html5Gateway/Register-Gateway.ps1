# Runs on a PVWA server: makes a PSM HTML5 Gateway known to PVWA, so that PVWA offers browser sessions through it.
# The PVWA configuration is the file PVConfiguration.xml in the Vault safe PVWAConfig. The vendor has no tool or
# REST call for this entry (in the web console: Options > Privileged Session Management), so the file is taken
# from the Vault with PACLI, two entries are added, and it is stored again:
#   <PSMGatewayServers><PSMGatewayServer ID="..."><PSMGatewayServerConnectionDetails Address="..." Port="443"/>
#   and, in the connection details of every PSM server, <PSMGateway ID="..." Enable="Yes"/>.
# Stage Register changes the file; stage Verify only reads it.
[CmdletBinding()]
param([ValidateSet('Register', 'Verify')][string]$Stage, [hashtable]$Settings, [string]$VaultPassword = '')
$ErrorActionPreference = 'Stop'
# PAEASY_INCLUDE_VAULT_PACLI

$gatewayId = [string]$Settings.GatewayId
$gatewayAddress = [string]$Settings.GatewayAddress
$gatewayPort = [string][int]$Settings.GatewayPort
if ($gatewayId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$' -or $gatewayAddress -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$') {
    throw 'The gateway needs a simple ID and a DNS name or address'
}
if (-not $VaultPassword) {
    throw 'The password of the Vault user Administrator is needed to read the PVWA configuration'
}
$work = [string]$Settings.WorkRoot
if ($work -notmatch '^[A-Za-z]:\\[A-Za-z0-9_.\\-]+$') {
    throw 'WorkRoot must be a local path without spaces'
}
# PACLI is only run from a folder that nobody but SYSTEM and the administrators can write to (the helper
# checks that). C:\ProgramData does not qualify, so the work folder gets its own closed permissions.
if (-not (Test-Path -LiteralPath $work)) {
    New-Item -ItemType Directory -Path $work -Force |
        Out-Null
}
$null = & icacls.exe $work /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "The work folder $work could not be closed to other users"
}
$pacliRoot = Join-Path $work 'PACLI'
$pacli = Join-Path $pacliRoot 'Pacli.exe'
if (-not (Test-Path -LiteralPath $pacli -PathType Leaf)) {
    # The PACLI package was uploaded as a ZIP; its Pacli.exe may sit in a subfolder.
    $unpacked = Join-Path $work 'PACLI-unpacked'
    if (Test-Path -LiteralPath $unpacked) {
        Remove-Item -LiteralPath $unpacked -Recurse -Force
    }
    Expand-Archive -LiteralPath ([string]$Settings.PacliArchive) -DestinationPath $unpacked -Force
    $found = @(Get-ChildItem -LiteralPath $unpacked -Recurse -Filter Pacli.exe -File)
    if ($found.Count -ne 1) {
        throw "Expected one Pacli.exe in the PACLI package; found $($found.Count)"
    }
    if (Test-Path -LiteralPath $pacliRoot) {
        Remove-Item -LiteralPath $pacliRoot -Recurse -Force
    }
    Move-Item -LiteralPath $found[0].Directory.FullName -Destination $pacliRoot
    Remove-Item -LiteralPath $unpacked -Recurse -Force -ErrorAction SilentlyContinue
}

function Set-GatewayEntries {
    # Adds or corrects the two kinds of entries in the loaded configuration. Returns $true when it changed something.
    param([xml]$Configuration)
    $changed = $false
    $servers = $Configuration.SelectSingleNode('//PSMServers')
    if (-not $servers) {
        throw 'The PVWA configuration has no PSM server yet. Install PSM first.'
    }
    $psmRoot = $servers.ParentNode
    $gateways = $psmRoot.SelectSingleNode('PSMGatewayServers')
    if (-not $gateways) {
        $gateways = $psmRoot.AppendChild($Configuration.CreateElement('PSMGatewayServers'))
        $changed = $true
    }
    $gateway = @($gateways.SelectNodes('PSMGatewayServer') | Where-Object { $_.GetAttribute('ID') -eq $gatewayId })[0]
    if (-not $gateway) {
        $gateway = $gateways.AppendChild($Configuration.CreateElement('PSMGatewayServer'))
        $gateway.SetAttribute('ID', $gatewayId)
        $changed = $true
    }
    $details = $gateway.SelectSingleNode('PSMGatewayServerConnectionDetails')
    if (-not $details) {
        $details = $gateway.AppendChild($Configuration.CreateElement('PSMGatewayServerConnectionDetails'))
        $changed = $true
    }
    if ($details.GetAttribute('Address') -ne $gatewayAddress -or $details.GetAttribute('Port') -ne $gatewayPort) {
        $details.SetAttribute('Address', $gatewayAddress)
        $details.SetAttribute('Port', $gatewayPort)
        $changed = $true
    }
    foreach ($server in @($servers.SelectNodes('PSMServer'))) {
        $connection = $server.SelectSingleNode('ConnectionDetails')
        if (-not $connection) {
            continue
        }
        $reference = $connection.SelectSingleNode('PSMGateway')
        if (-not $reference) {
            # The schema wants PSMGateway right after TSGateway.
            $reference = $Configuration.CreateElement('PSMGateway')
            $after = $connection.SelectSingleNode('TSGateway')
            if ($after) {
                $null = $connection.InsertAfter($reference, $after)
            } else {
                $null = $connection.AppendChild($reference)
            }
            $changed = $true
        }
        if ($reference.GetAttribute('ID') -ne $gatewayId -or $reference.GetAttribute('Enable') -ne 'Yes') {
            $reference.SetAttribute('ID', $gatewayId)
            $reference.SetAttribute('Enable', 'Yes')
            $changed = $true
        }
    }
    return $changed
}

$folder = Join-Path $work 'config'
if (Test-Path -LiteralPath $folder) {
    Remove-Item -LiteralPath $folder -Recurse -Force
}
New-Item -ItemType Directory -Path $folder -Force |
    Out-Null
$file = Join-Path $folder 'PVConfiguration.xml'
$transfer = @('SAFE=PVWAConfig', 'FOLDER=Root', 'FILE=PVConfiguration.xml', ('LOCALFOLDER=' + $folder), 'LOCALFILE=PVConfiguration.xml')
$session = $null
$changed = $false
$psmServers = 0
try {
    $session = Open-PAPacliVaultSession $pacli $VaultPassword -Address ([string]$Settings.VaultAddress)
    $null = Open-PAPacliSafe $session 'PVWAConfig'
    try {
        $got = Invoke-PAPacliProcess -Pacli $pacli -Operation RETRIEVEFILE -SessionId $session.Id -Arguments $transfer -TimeoutSeconds 60
        if (-not (Test-PAPacliCleanAcknowledgement $got) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw 'The PVWA configuration could not be read from the Vault'
        }
        $configuration = New-Object xml
        $configuration.PreserveWhitespace = $true
        $configuration.Load($file)
        $psmServers = @($configuration.SelectNodes('//PSMServers/PSMServer')).Count
        if ($Stage -eq 'Register') {
            $changed = Set-GatewayEntries $configuration
            if ($changed) {
                $configuration.Save($file)
                $put = Invoke-PAPacliProcess -Pacli $pacli -Operation STOREFILE -SessionId $session.Id -Arguments $transfer -TimeoutSeconds 60
                if (-not (Test-PAPacliCleanAcknowledgement $put)) {
                    throw 'The changed PVWA configuration could not be stored in the Vault'
                }
            }
        } else {
            # Verify: the file as it is in the Vault must not need a change.
            $changed = Set-GatewayEntries $configuration
        }
    } finally {
        Close-PAPacliSafe $session 'PVWAConfig'
    }
} finally {
    if ($session) {
        Close-PAPacliVaultSession $session
    }
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
}
if ($Stage -eq 'Verify') {
    return [pscustomobject]@{
        Passed = (-not $changed -and $psmServers -gt 0)
        Message = "Gateway '$gatewayId' ($gatewayAddress`:$gatewayPort) is set for $psmServers PSM server(s) in the PVWA configuration: $(-not $changed)"
        Evidence = @("PsmServers=$psmServers")
    }
}
if ($changed) {
    # PVWA reads its configuration when the application starts.
    Import-Module WebAdministration -ErrorAction Stop
    Restart-WebAppPool -Name 'PasswordVaultWebAccessPool' -ErrorAction Stop
}
return [pscustomobject]@{Changed = $changed; Message = "Gateway '$gatewayId' ($gatewayAddress`:$gatewayPort) registered for $psmServers PSM server(s) in the PVWA configuration" }
