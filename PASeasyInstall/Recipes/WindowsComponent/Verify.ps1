# Read-only stage validation: never modify vendor logs to manufacture success.
param([Parameter(Mandatory)][string]$Stage, [Parameter(Mandatory)][hashtable]$Settings)
. (Join-Path $PSScriptRoot 'Workspace.ps1')
Protect-PASeasyComponentWorkspace -Settings $Settings -ValidateOnly
$root = [string]$Settings.StageRoot
$type = [string]$Settings.Type
if ($type -eq 'PVWA') {
    . (Join-Path $PSScriptRoot 'PvwaTls.ps1')
    if ($Stage -eq 'ConfigureTLS') {
        $tls = Test-PASeasyPvwaTls -Settings $Settings
        return [pscustomobject]@{
            Passed = [bool]$tls.Passed
            Detail = 'PVWA effective IIS TLS binding, certificate trust/name and required SSL verified'
            Evidence = @($tls)
        }
    }
    if ($Stage -eq 'Preflight') { $null = Test-PASeasyPvwaTlsPreparation -Settings $Settings }
}
if ($type -eq 'CPM' -and $Stage -eq 'ConfigureTLS') {
    . (Join-Path $PSScriptRoot 'CpmTls.ps1')
    return Test-PASeasyCpmTls -Settings $Settings
}
if ($type -eq 'PSM') {
    . (Join-Path $PSScriptRoot 'Psm.ps1')
    return (Invoke-PASeasyPsmVerify -Stage $Stage -Settings $Settings)
}
$tlsEvidence = $null
if ($type -eq 'PVWA' -and $Stage -eq 'Verify') { $tlsEvidence = Test-PASeasyPvwaTls -Settings $Settings }
$marker = Join-Path (Join-Path $root 'stage') ($Stage + '.json')
$passed = $false
$evidence = @()
if ($tlsEvidence) { $evidence += $tlsEvidence }
if ($Stage -eq 'Preflight') {
    $passed = (Test-Path -LiteralPath ([string]$Settings.MediaTarget) -PathType Leaf)
    $evidence += 'Staged installer media exists'
} elseif ($Stage -eq 'Extract') {
    $passed = (Test-Path $marker) -and @(Get-ChildItem -LiteralPath (Join-Path $root 'payload') -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue).Count -gt 0
} elseif ($Stage -eq 'Prerequisites') {
    $issues = @()
    $release = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction SilentlyContinue
    if (-not $release -or [int]$release.Release -lt 528040) { $issues += '.NET Framework 4.8 missing' }
    foreach ($architecture in @('x86', 'x64')) {
        $base = if ($architecture -eq 'x86') { 'HKLM:\SOFTWARE\WOW6432Node' }else { 'HKLM:\SOFTWARE' }
        $runtime = Get-ItemProperty -LiteralPath ($base + '\Microsoft\VisualStudio\14.0\VC\Runtimes\' + $architecture) -ErrorAction SilentlyContinue
        if (-not $runtime -or [int]$runtime.Installed -ne 1) { $issues += "VC runtime $architecture missing" }
        else { $evidence += ('VC ' + $architecture + ' ' + $runtime.Version) }
    }
    if ($type -eq 'PVWA') {
        # Exact required feature names from supplied v15 PVWA_InstallWebServerRoles.
        $required = @('Web-Server', 'Web-WebServer', 'Web-Common-Http', 'Web-Static-Content', 'Web-Default-Doc', 'Web-Dir-Browsing', 'Web-Http-Errors', 'Web-Http-Redirect', 'Web-App-Dev', 'Web-ASP', 'Web-ISAPI-Ext', 'Web-ISAPI-Filter', 'Web-Health', 'Web-Http-Logging', 'Web-Request-Monitor', 'Web-Security', 'Web-Basic-Auth', 'Web-Windows-Auth', 'Web-Filtering', 'Web-Mgmt-Tools', 'Web-Mgmt-Service', 'Web-Mgmt-Console', 'Web-Scripting-Tools', 'Web-Mgmt-Compat', 'Web-Metabase', 'Web-WMI', 'PowerShell', 'Web-WebSockets', 'NET-WCF-HTTP-Activation45')
        $features = @(Get-WindowsFeature -Name $required -ErrorAction Stop)
        $missing = @($features | Where-Object { -not $_.Installed })
        if ($features.Count -ne $required.Count -or
            $missing.Count) { $issues += ('Required IIS/.NET features absent: ' + (($missing | ForEach-Object { $_.Name }) -join ', ')) }
        else { $evidence += ('All ' + $required.Count + ' required Windows features installed') }
    } elseif ($type -eq 'CPM') {
        $openssl = Join-Path $root 'payload\InstallationAutomation\Registration\RegistrationTool\openssl.exe'
        if (-not(Test-Path -LiteralPath $openssl)) { $issues += 'Archive OpenSSL missing' }else {
            $version = @(& $openssl version 2>&1)
            $nativeCode = $LASTEXITCODE
            if ($nativeCode -ne 0 -or ($version -join '') -notmatch '^OpenSSL 3\.') { $issues += 'Archive OpenSSL cannot run' }
            else { $evidence += ([string]$version[0]) }
        }
    }
    $passed = (Test-Path -LiteralPath $marker) -and $issues.Count -eq 0
    $evidence += $issues
} elseif ($Stage -eq 'Install') {
    $pattern = switch ($type) { 'PVWA' { 'CyberArk Scheduled Tasks' } 'CPM' { 'CyberArk Password Manager|CyberArk CPM|CyberArk Central Policy Manager' } 'PSM' { 'CyberArk PSM|Cyber-?Ark Privileged Session Manager' } }
    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern -or $_.DisplayName -match $pattern })
    $passed = (Test-Path $marker) -and $services.Count -gt 0
    $evidence += @($services | ForEach-Object { $_.Name + '=' + $_.Status })
} elseif ($Stage -eq 'Harden') {
    $issues = @()
    if (-not [bool]$Settings.ApplyHardening) {
        $passed = Test-Path -LiteralPath $marker -PathType Leaf
        $evidence += 'Hardening skipped by explicit lab policy; effective vendor controls NotTested'
    } else {
        # Independent observations of enabled controls in the supplied v15 hardening XML.
        foreach ($serviceName in @('RemoteAccess', 'SCardSvr', 'SCPolicySvc', 'SNMPTRAP', 'sacsvr', 'WerSvc')) {
            $service = Get-CimInstance Win32_Service -Filter ("Name='" + $serviceName + "'") -ErrorAction Stop
            if ($service -and $service.StartMode -ne 'Disabled') { $issues += ("Vendor-disabled service still enabled: " + $serviceName) }
            $evidence += ($serviceName + '=' + $(if ($service) { $service.StartMode }else { 'Absent' }))
        }
        if ($type -eq 'PVWA') {
            $protocols = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
            foreach ($protocol in @('SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1')) {
                foreach ($side in @('Client', 'Server')) {
                    $value = Get-ItemProperty -LiteralPath (Join-Path $protocols ($protocol + '\' + $side)) -ErrorAction SilentlyContinue
                    if (-not $value -or
                        [int]$value.Enabled -ne 0 -or
                        [int]$value.DisabledByDefault -ne 1) { $issues += ($protocol + ' ' + $side + ' not disabled') }
                    else { $evidence += ($protocol + ' ' + $side + ' Enabled=0 DisabledByDefault=1') }
                }
            }
            foreach ($base in @('HKLM:\SOFTWARE\Microsoft', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft')) {
                $value = Get-ItemProperty -LiteralPath ($base + '\.NETFramework\v4.0.30319') -ErrorAction SilentlyContinue
                if (-not $value -or
                    [int]$value.SchUseStrongCrypto -ne 1) { $issues += '.NET strong cryptography not enabled' }else { $evidence += ($base + ' SchUseStrongCrypto=1') }
            }
            $machine = Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\Config\machine.config'
            $xml = [xml](Get-Content -LiteralPath $machine -Raw -ErrorAction Stop)
            if ($xml.configuration.'system.web'.deployment.retail -ne 'true') { $issues += '.NET retail mode is not enabled' }else { $evidence += '.NET Framework64 retail=true' }
            Import-Module WebAdministration -ErrorAction Stop
            $browse = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/directoryBrowse' -Name enabled -ErrorAction Stop
            if ([bool]$browse.Value) { $issues += 'IIS directory browsing is enabled' }else { $evidence += 'IIS directoryBrowse enabled=false' }
        } elseif ($type -eq 'CPM') {
            $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | ForEach-Object { $_.SID.Value })
            foreach ($pair in @(@{
                        Service = 'CyberArk Password Manager'
                        User = 'PasswordManagerUser'
                    }, @{
                        Service = 'CyberArk Central Policy Manager Scanner'
                        User = 'ScannerUser'
                    })) {
                $service = Get-CimInstance Win32_Service -Filter ("Name='" + $pair.Service + "'") -ErrorAction Stop
                $user = Get-LocalUser -Name $pair.User -ErrorAction SilentlyContinue
                if (-not $service -or
                    $service.StartName -notin @(('.\' + $pair.User), ($env:COMPUTERNAME + '\' + $pair.User))) { $issues += ('Unexpected service principal: ' + $pair.Service) }
                if (-not $user -or
                    -not $user.Enabled -or
                    $user.SID.Value -in $admins) { $issues += ('Service user is absent, disabled, or administrator: ' + $pair.User) }
                $evidence += ($pair.Service + ' StartName=' + $service.StartName + '; ' + $pair.User + ' Enabled=' + $user.Enabled + ' Administrator=' + ($user.SID.Value -in $admins))
            }
        }
        $passed = (Test-Path -LiteralPath $marker -PathType Leaf) -and $issues.Count -eq 0
        $evidence += @($issues)
        if (-not $issues.Count) { $evidence += 'Independent enabled vendor controls verified; functional health is separate' }
    }
} elseif ($Stage -eq 'Verify') {
    $pattern = switch ($type) { 'PVWA' { 'CyberArk Scheduled Tasks' } 'CPM' { 'CyberArk Password Manager|CyberArk CPM|CyberArk Central Policy Manager' } 'PSM' { 'CyberArk PSM|Cyber-?Ark Privileged Session Manager' } }
    $services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern -or $_.DisplayName -match $pattern })
    $passed = $services.Count -gt 0 -and @($services | Where-Object { $_.Status -ne 'Running' }).Count -eq 0
    $evidence += @($services | ForEach-Object { $_.Name + '=' + $_.Status })
} else {
    $passed = Test-Path -LiteralPath $marker -PathType Leaf
    if ($Stage -eq 'Register') { $evidence += 'Vendor stage completed; independent API authentication not yet tested' }
}
return [pscustomobject]@{
    Passed = [bool]$passed
    Evidence = @($evidence)
    Message = $(if ($passed) { "$type $Stage check passed" }else { "$type $Stage not verified" })
}
