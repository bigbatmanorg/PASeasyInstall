# Read-only primary acceptance: services, product startup evidence and authenticated PACLI login.
param([Parameter(Mandatory=$true)][hashtable]$Settings,[Parameter(Mandatory=$true)][string]$AdminPassword,
      [ValidateRange(0,900)][int]$ReadinessTimeoutSeconds=180)
# PAEASY_INCLUDE_VAULT_PACLI
$ErrorActionPreference='Stop'
# Resume can revalidate this postcondition before the later readiness node. Delayed-auto
# services legitimately remain stopped for a short interval after hardening/reboot.
$names=@('PrivateArk Database','PrivateArk Server','CyberArk Logic Container','Cyber-Ark Event Notification Engine')
$deadline=[DateTime]::UtcNow.AddSeconds($ReadinessTimeoutSeconds)
do {
    $down=@($names | Where-Object { $svc=Get-Service -DisplayName $_ -ErrorAction SilentlyContinue; -not $svc -or $svc.Status -ne 'Running' })
    if(-not $down.Count -or [DateTime]::UtcNow -ge $deadline){break}
    Start-Sleep -Seconds 5
} while($true)
$issues=@();$ev=@()
foreach($name in @('PrivateArk Database','PrivateArk Server','CyberArk Logic Container','Cyber-Ark Event Notification Engine')){
    $s=Get-Service -DisplayName $name -ErrorAction SilentlyContinue
    if(-not $s -or $s.Status -ne 'Running'){$issues+="$name not running"}
}
if(-not $issues.Count){$ev+='4 Vault services running'}
$italog=Join-Path $Settings.InstallRoot 'Server\Logs\italog.log'
if(-not(Test-Path -LiteralPath $italog)){$issues+='italog.log missing'}else{
    # The server-up record must postdate the latest boot (a record from before a reboot proves nothing now).
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $up=@(Get-Content -LiteralPath $italog -Tail 3000 | Where-Object {$_ -match 'ITADB313I Server .* is up'} | Where-Object {
        $m=[regex]::Match($_,'^(\d\d/\d\d/\d{4})\s+(\d\d:\d\d:\d\d)'); $m.Success -and [datetime]::ParseExact($m.Groups[1].Value+' '+$m.Groups[2].Value,'dd/MM/yyyy HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture) -ge $boot.AddSeconds(-5) })
    if(-not $up.Count){$issues+="no ITADB313I server-up record since boot $($boot.ToString('s'))"}else{$ev+='ITADB313I current-boot server-up record verified'}
}
$pacli=Join-Path (Join-Path $Settings.PackagesRoot 'PACLI') 'Pacli.exe'
$session=$null;$closed=$true
if(-not(Test-Path -LiteralPath $pacli)){$issues+='PACLI missing'}
if(-not $issues.Count){
    try {
        $closed=$false
        $session=Open-PAPacliVaultSession $pacli $AdminPassword
        if(-not $session.Authenticated){throw 'PACLI independent authentication proof missing'}
        $ev+='PACLI independent authenticated identity verified'
    } catch {
        if($_.Exception.Data['PAPacliSessionClosed'] -is [bool] -and $_.Exception.Data['PAPacliSessionClosed']){
            $closed=$true;$issues+='PACLI authenticated identity not verified'
            if(-not $_.Exception.Data['PAPacliAuthAttempted']){$ev+='PACLI authNotAttempted'}
        }else{throw}
    } finally {
        if($session){Close-PAPacliVaultSession $session;$closed=[bool]$session.Closed}
    }
    if(-not $closed){throw 'PAExecUnknown: primary verification session closure is unconfirmed'}
    $ev+='PACLI isolated session closure verified'
}else{$ev+='PACLI authNotAttempted: local readiness failed'}
$lic=Join-Path $Settings.InstallRoot 'Server\Conf\License.xml'
if(Test-Path -LiteralPath $lic){ try{$x=[xml](Get-Content -LiteralPath $lic -Raw);$ev+=('license expiration '+[string]$x.LicenseXML.Limitations.LicenseLimitations.ExpirationDate)}catch{$ev+='license present'} }
[pscustomobject]@{Passed=($issues.Count -eq 0);Message=($issues -join ';');Evidence=$ev;SessionClosed=[bool]$closed}
