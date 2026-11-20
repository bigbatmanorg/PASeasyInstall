# Runs on the TARGET under WinRM or a recoverable SYSTEM scheduled task.
# Commands below are adapted from the supplied CyberArk v15 vendor Ansible role workflows.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Preflight','Extract','Prerequisites','Install','ConfigureTLS','Register','Harden','PostInstall','Verify')][string]$Stage,
      [Parameter(Mandatory)][hashtable]$Settings,[string]$VaultPassword='')
$ErrorActionPreference='Stop'
$id=[string]$Settings.Id;$type=[string]$Settings.Type
if($type -notin @('PVWA','CPM','PSM')){throw "Unsupported Windows recipe type: $type"}
$root=[string]$Settings.StageRoot;$media=[string]$Settings.MediaTarget
$markerRoot=Join-Path $root 'stage';$payload=Join-Path $root 'payload'
$opts=$Settings.Options;if(-not $opts){$opts=@{}}
function Get-Option([string]$Name,[string]$Default='') {
    if($opts.Contains($Name) -and $null -ne $opts[$Name]){return [string]$opts[$Name]};return $Default
}
function Get-VendorScript([string]$FileName) {
    $candidates=@(Get-ChildItem -LiteralPath $payload -Filter $FileName -File -Recurse -ErrorAction SilentlyContinue)
    if($candidates.Count -ne 1){throw "Expected exactly one vendor script '$FileName' under $payload; found $($candidates.Count). Check the selected media archive."}
    return $candidates[0].FullName
}
function Set-XmlParameter([string]$XmlPath,[string]$Name,[string]$Value) {
    if(-not(Test-Path -LiteralPath $XmlPath)){throw "Missing vendor XML configuration $XmlPath"}
    $xml=[xml](Get-Content -LiteralPath $XmlPath -Raw)
    $node=$xml.SelectSingleNode("//Parameter[@Name='$Name']")
    if(-not $node){throw "XML parameter '$Name' absent from $XmlPath"}
    if($node.Attributes['Value']){$node.SetAttribute('Value',$Value)}else{$node.Value=$Value}
    $xml.Save($XmlPath)
}
function Write-Marker([string]$Name,[string]$Message) {
    New-Item -ItemType Directory -Path $markerRoot -Force|Out-Null
    [IO.File]::WriteAllText((Join-Path $markerRoot ($Name+'.json')),
        (@{schemaVersion=1;stage=$Name;utc=[DateTime]::UtcNow.ToString('o');message=$Message}|ConvertTo-Json),
        [Text.UTF8Encoding]::new($false))
}
. (Join-Path $PSScriptRoot 'Vendor.ps1')
. (Join-Path $PSScriptRoot 'Archive.ps1')
. (Join-Path $PSScriptRoot 'Workspace.ps1')
Protect-PASeasyComponentWorkspace -Settings $Settings
try {
if($type -eq 'PVWA'){
    . (Join-Path $PSScriptRoot 'PvwaTls.ps1')
    if($Stage -eq 'Preflight'){$null=Test-PASeasyPvwaTlsPreparation -Settings $Settings}
    if($Stage -eq 'ConfigureTLS'){return Invoke-PASeasyPvwaTls -Settings $Settings}
}
if($type -eq 'CPM' -and $Stage -eq 'ConfigureTLS'){
    . (Join-Path $PSScriptRoot 'CpmTls.ps1')
    return Invoke-PASeasyCpmTls -Settings $Settings
}
if($type -eq 'PSM' -and $Stage -in @('Prerequisites','Install','Register','Harden','PostInstall')){
    . (Join-Path $PSScriptRoot 'Psm.ps1')
    return Invoke-PASeasyPsmStage -Stage $Stage -Settings $Settings -VaultPassword $VaultPassword
}

function Test-ComponentServices {
    $pattern=switch($type){'PVWA'{'CyberArk Scheduled Tasks'} 'CPM'{'CyberArk Password Manager|CyberArk Central Policy Manager|CyberArk CPM'} 'PSM'{'CyberArk PSM|Cyber-?Ark Privileged Session Manager'}}
    return @(Get-Service -ErrorAction SilentlyContinue | Where-Object {$_.Name -match $pattern -or $_.DisplayName -match $pattern})
}
if($Stage -eq 'Preflight'){
    if(-not(Test-Path -LiteralPath $media -PathType Leaf)){throw "Staged media missing: $media"}
    if((Get-CimInstance Win32_OperatingSystem).ProductType -ne 3){throw 'Windows Server required for this recipe'}
    return [pscustomobject]@{Changed=$false;Message="$type host preflight successful"}
}
if($Stage -eq 'Extract'){
    if(-not(Test-Path -LiteralPath $payload -PathType Container)){
        $null=Expand-PASeasyComponentArchive -Source $media -Destination $payload
    }elseif(-not(Test-Path -LiteralPath (Join-Path $markerRoot 'Extract.json'))){throw 'Existing payload has no completed extraction marker; reconcile or restore before retry'}
    if(-not @(Get-ChildItem -Path $payload -Recurse -Filter '*.ps1' -File).Count){throw 'No PowerShell vendor automation scripts found in media. Archive may be wrong.'}
    Write-Marker $Stage 'Archive extracted'
    return [pscustomobject]@{Changed=$true;Message='Media extracted and scripts located'}
}
if($Stage -eq 'Prerequisites'){
    if($type -eq 'PVWA'){
        $cmd=Get-VendorScript 'PVWA_Prerequisites.ps1'
        $result=Invoke-VendorScript $cmd
    }elseif($type -eq 'CPM'){
        # v15 pre-installation invokes OpenSSL before its installation stage deploys VC runtimes.
        # Use the archive's signed redistributables first; do not accept a vendor success JSON
        # when its native FIPS command cannot load its DLL dependencies.
        foreach($architecture in @('x86','x64')){
            $name='VC_redist.'+$architecture+'.exe'
            $candidates=@(Get-ChildItem -LiteralPath (Join-Path $payload 'ISSetupPrerequisites') -Recurse -File -Filter $name)
            if($candidates.Count -ne 1){throw "Expected exactly one archive prerequisite $name"}
            $process=Start-Process -FilePath $candidates[0].FullName -ArgumentList '/install /quiet /norestart' -Wait -PassThru
            if($process.ExitCode -notin @(0,3010,1638)){throw "Archive prerequisite $name failed ($($process.ExitCode))"}
            $registryBase=if($architecture -eq 'x86'){'HKLM:\SOFTWARE\WOW6432Node'}else{'HKLM:\SOFTWARE'}
            $runtime=Get-ItemProperty -LiteralPath ($registryBase+'\Microsoft\VisualStudio\14.0\VC\Runtimes\'+$architecture) -ErrorAction SilentlyContinue
            if(-not $runtime -or [int]$runtime.Installed -ne 1){throw "VC runtime $architecture installation not independently verified"}
        }
        $cmd=Get-VendorScript 'CPM_PreInstallation.ps1'
        $result=Invoke-VendorScript $cmd
    }else{
        $cmd=Get-VendorScript 'Execute-Stage.ps1';$xml=Join-Path (Split-Path -Parent $cmd) 'Prerequisites\PrerequisitesConfig.xml'
        $result=Invoke-VendorScript -ScriptPath $cmd -Parameters @{configFilePath=$xml;silentMode='Silent';displayJson=$true;delayedrestart=$true}
        if($result.restartRequired){throw 'PSM prerequisite requires reboot. Explicit reboot orchestration must be qualified before automatically continuing.'}
    }
    Write-Marker $Stage 'Vendor prerequisites successful'
    return [pscustomobject]@{Changed=$true;Message="$type prerequisites completed"}
}
if($Stage -eq 'Install'){
    if($type -eq 'PVWA'){
        $cmd=Get-VendorScript 'PVWAInstallation.ps1'
        $xml=Join-Path (Split-Path -Parent $cmd) 'InstallationConfig.xml'
        if($opts.Contains('installDirectory')){Set-XmlParameter $xml 'PVWAInstallDirectory' ([string]$opts.installDirectory)}
        if($opts.Contains('applicationDirectory')){Set-XmlParameter $xml 'PVWAApplicationDirectory' ([string]$opts.applicationDirectory)}
        if($opts.Contains('applicationName')){Set-XmlParameter $xml 'PVWAApplicationName' ([string]$opts.applicationName)}
        $result=Invoke-VendorScript $cmd
    }elseif($type -eq 'CPM'){
        $cmd=Get-VendorScript 'CPMInstallation.ps1'
        $xml=Join-Path (Split-Path -Parent $cmd) 'InstallationConfig.xml'
        if($opts.Contains('installDirectory')){Set-XmlParameter $xml 'CPMInstallDirectory' ([string]$opts.installDirectory)}
        $result=Invoke-VendorScript $cmd
    }else{
        $cmd=Get-VendorScript 'Execute-Stage.ps1';$xml=Join-Path (Split-Path -Parent $cmd) 'Installation\InstallationConfig.xml'
        if($opts.Contains('installDirectory')){Set-XmlParameter $xml 'InstallationDirectory' ([string]$opts.installDirectory)}
        $result=Invoke-VendorScript -ScriptPath $cmd -Parameters @{configFilePath=$xml;silentMode='Silent';displayJson=$true;delayedrestart=$true}
        if($result.restartRequired){throw 'PSM installer requires reboot. No automatic plaintext Winlogon autologon is permitted; reconcile and qualify secure continuation.'}
    }
    $services=Test-ComponentServices
    if(-not $services.Count){throw 'Vendor installation reported success but expected services are absent'}
    Write-Marker $Stage 'Vendor installer succeeded and services were discovered'
    return [pscustomobject]@{Changed=$true;Message="$type installed; discovered $($services.Count) services"}
}
if($Stage -eq 'Register'){
    if(-not $VaultPassword){throw 'Vault registration requires VaultAdmin secure secret reference'}
    $vaultSecure=ConvertTo-SecureString -String $VaultPassword -AsPlainText -Force
    if($type -eq 'PVWA'){
        $cmd=Get-VendorScript 'PVWARegisterComponent.ps1'
        $xml=Join-Path (Split-Path -Parent $cmd) 'PVWARegisterComponentConfig.xml'
        Set-XmlParameter $xml 'vaultip' ([string]$Settings.VaultAddress)
        Set-XmlParameter $xml 'vaultport' (Get-Option 'vaultPort' '1858')
        Set-XmlParameter $xml 'vaultuser' ([string]$Settings.VaultUser)
        $base=Get-Option 'installDirectory' 'C:\CyberArk\Password Vault Web Access'
        $application=Get-Option 'applicationDirectory' 'C:\inetpub\wwwroot\PasswordVault'
        Set-XmlParameter $xml 'configFilesPath' $base
        Set-XmlParameter $xml 'installpackagedir' $application
        Set-XmlParameter $xml 'virtualDirectoryPath' $application
        Set-XmlParameter $xml 'PVWAApplicationName' (Get-Option 'applicationName' 'PasswordVault')
        Set-XmlParameter $xml 'pvwaUrl' (Get-Option 'pvwaUrl' ('https://'+$env:COMPUTERNAME+'/PasswordVault'))
        $result=Invoke-VendorScript -ScriptPath $cmd -Parameters @{spwdObj=$vaultSecure}
    }elseif($type -eq 'CPM'){
        $cmd=Get-VendorScript 'CPMRegisterCommponent.ps1'
        $xml=Join-Path (Split-Path -Parent $cmd) 'CPMRegisterComponentConfig.xml'
        $registrationMode=Get-Option 'registrationMode' 'Clean'
        if($registrationMode -notin @('Clean','Upgrade')){throw 'CPM registrationMode must be Clean or Upgrade'}
        Set-XmlParameter $xml 'isUpgrade' $(if($registrationMode -eq 'Upgrade'){'true'}else{'false'})
        Set-XmlParameter $xml 'installDirectory' (Get-Option 'installDirectory' 'C:\Program Files (x86)\CyberArk')
        Set-XmlParameter $xml 'username' (Get-Option 'cpmUser' 'PasswordManager')
        Set-XmlParameter $xml 'vaultip' ([string]$Settings.VaultAddress)
        Set-XmlParameter $xml 'vaultPort' (Get-Option 'vaultPort' '1858')
        Set-XmlParameter $xml 'vaultUser' ([string]$Settings.VaultUser)
        Set-XmlParameter $xml 'validatePVWASecureConnect' $(if([bool]$Settings.ValidateTLS){'true'}else{'false'})
        $result=Invoke-VendorScript -ScriptPath $cmd -Parameters @{spwdObj=$vaultSecure}
    }else{
        $cmd=Get-VendorScript 'Execute-Stage.ps1'
        $xml=Get-VendorScript 'RegistrationConfig.xml'
        Set-XmlParameter $xml 'vaultip' ([string]$Settings.VaultAddress)
        Set-XmlParameter $xml 'vaultport' (Get-Option 'vaultPort' '1858')
        Set-XmlParameter $xml 'vaultusername' ([string]$Settings.VaultUser)
        Set-XmlParameter $xml 'accepteula' 'yes'
        $result=Invoke-VendorScript -ScriptPath $cmd -Parameters @{configFilePath=$xml;silentMode='Silent';displayJson=$true;spwdObj=$vaultSecure}
    }
    Write-Marker $Stage 'Registration sequence finished'
    return [pscustomobject]@{Changed=$true;Message="$type registration attempted; verify service and connectivity separately"}
}
if($Stage -eq 'Harden'){
    if(-not [bool]$Settings.ApplyHardening){Write-Marker $Stage 'Lab mode: hardening deliberately skipped';return [pscustomobject]@{Changed=$false;Message='Hardening skipped by explicit lab policy'}}
    if($type -eq 'PVWA'){$cmd=Get-VendorScript 'PVWA_Hardening.ps1';$result=Invoke-VendorScript $cmd}
    elseif($type -eq 'CPM'){
        $file=Get-Option 'hardeningScript' 'CPM_Hardening.ps1';$cmd=Get-VendorScript $file;$result=Invoke-VendorScript -ScriptPath $cmd -ResultSource Information
    }else{
        $cmd=Get-VendorScript 'Execute-Stage.ps1';$xml=Join-Path (Split-Path -Parent $cmd) 'Hardening\HardeningConfig.xml'
        $result=Invoke-VendorScript -ScriptPath $cmd -Parameters @{configFilePath=$xml;silentMode='Silent';displayJson=$true;delayedrestart=$true}
        if($result.restartRequired){throw 'PSM hardening requires reboot and controlled continuation; no autologon credentials written'}
    }
    Write-Marker $Stage 'Vendor hardening stage succeeded'
    return [pscustomobject]@{Changed=$true;Message="$type hardening stage completed"}
}
if($Stage -eq 'Verify'){
    $services=Test-ComponentServices
    if(-not $services.Count){throw 'No component services found'}
    $stopped=@($services|Where-Object {$_.Status -ne 'Running'})
    if($stopped.Count){throw "Component service(s) not running: $(@($stopped|ForEach-Object{$_.Name}) -join ', ')"}
    Write-Marker $Stage 'Component services running; functional integration tests remain separate'
    return [pscustomobject]@{Changed=$false;Message="$type services running; functional validation must be qualified"}
}

} finally {
    # Stages may create files under a temporary management/domain principal.
    Protect-PASeasyComponentWorkspace -Settings $Settings
}
