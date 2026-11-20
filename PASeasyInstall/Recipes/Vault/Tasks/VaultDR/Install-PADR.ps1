# PADR silent install (detached, SYSTEM). Must run BEFORE hardening: StandardVault hardening disables msiserver.
param([Parameter(Mandatory=$true)][hashtable]$Settings,[Parameter(Mandatory=$true)][string]$DRPassword)
$ErrorActionPreference='Stop'
# PAEASY_INCLUDE_VAULT_PADR
if($DRPassword -match '[\r\n]'){throw 'Unsafe newline in DR password'}
$folder=Join-Path $Settings.PackagesRoot 'Disaster Recovery'
$installer=Join-Path $folder 'setup.exe'
if(-not(Test-Path -LiteralPath $installer)){throw 'PADR setup.exe missing'}
if(Get-Service -DisplayName 'CyberArk Vault Disaster Recovery' -ErrorAction SilentlyContinue){throw 'PADR already installed; refusing to rerun'}
$iss=Join-Path $folder 'setup.iss'
$template=Join-Path $Settings.AutomationRoot 'Templates\vaultdr-iss.j2'
if(-not(Test-Path -LiteralPath $template)){throw 'Vendor DR response template missing'}
if(Test-Path -LiteralPath $iss){throw 'Existing DR installer response; restore/inspect before rerunning'}
$primary=[string]([Net.IPAddress]::Parse([string]$Settings.PrimaryIP))
$text=[IO.File]::ReadAllText($template)
$text=$text.Replace('{{ vault_installation_path }}',[string]$Settings.InstallRoot).Replace('{{ ansible_stripped_password }}',$DRPassword)
# The vendor template targets loopback (cloud image); on-premises DR must point at the primary Vault.
$text=$text.Replace('MasterVaultAddress=127.0.0.1','MasterVaultAddress='+$primary)
if(@([regex]::Matches($text,'(?im)^BootOption=0\s*$')).Count -ne 1 -or @([regex]::Matches($text,'(?im)^BootOption=')).Count -ne 1){throw 'PADR response must contain exactly one BootOption=0 (no reboot)'}
if($text -match '{{[^}]+}}'){throw 'Unresolved DR response template variable'}
if($text -notmatch ('(?m)^MasterVaultAddress='+[regex]::Escape($primary)+'\s*$')){throw 'DR response has incorrect primary address'}
try {
    [IO.File]::WriteAllText($iss,$text,[Text.Encoding]::ASCII)
    $acl=& icacls.exe $iss /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' 2>&1
    if($LASTEXITCODE -ne 0){throw 'Could not restrict response file'}
    $p=Start-Process -FilePath $installer -WorkingDirectory $folder -ArgumentList '/runfromtemp /clone_wait /w /s' -Wait -PassThru
    $deadline=(Get-Date).AddMinutes(20)
    while((Get-Process -Name setup,ISBEW64 -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline){Start-Sleep -Seconds 10}
    if(Get-Process -Name setup,ISBEW64 -ErrorAction SilentlyContinue){throw 'PADR installer processes still active after timeout; reconcile existing attempt, do not rerun'}
    $log=Join-Path $folder 'setup.log'
    if(-not(Test-Path -LiteralPath $log)){throw "PADR setup.log missing (exit $($p.ExitCode))"}
    $result=Get-Content -LiteralPath $log | Where-Object {$_ -match '^ResultCode='} | Select-Object -Last 1
    if($result -notmatch '^ResultCode=0\s*$'){throw "PADR setup.log not successful: $result"}
    # This contains the service AFTER setup returns. It is not evidence that setup itself never
    # started PADR: the native first-start window requires separate live/vendor qualification.
    Assert-PASeasyPadrNotActivated $Settings
    $service=Get-Service -DisplayName 'CyberArk Vault Disaster Recovery' -ErrorAction Stop
    Set-Service -Name $service.Name -StartupType Manual
    if($service.Status -ne 'Stopped'){
        Stop-Service -Name $service.Name -Force -ErrorAction Stop
        throw 'PADR unexpectedly started during no-reboot setup; stopped/manual for inspection, initial-start outcome requires reconciliation'
    }
    Assert-PASeasyPadrNotActivated $Settings
    [void](Set-PASeasyPadrIniValue (Join-Path $Settings.InstallRoot 'PADR\Conf\PADR.ini') 'EnableFailover' 'No')
    Assert-PASeasyPadrManualStandby $Settings
} finally {Remove-Item -LiteralPath $iss -Force -ErrorAction SilentlyContinue}
[pscustomobject]@{Changed=$true;Message="PADR installed toward primary $primary; setup.log ResultCode=0; manual failover policy verified, PADR stopped/manual awaiting Configure"}
