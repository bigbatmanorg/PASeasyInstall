param([Parameter(Mandatory=$true)][hashtable]$Settings)
$issues=@();$ev=@()
foreach($n in @('PrivateArk Database','PrivateArk Server','CyberArk Logic Container','Cyber-Ark Event Notification Engine')){ if(-not(Get-Service -DisplayName $n -ErrorAction SilentlyContinue)){$issues+="service $n missing"} }
$bin=Join-Path $Settings.InstallRoot 'Server\CAVaultManager.exe'
if(Test-Path -LiteralPath $bin){$ev+="CAVaultManager $((Get-Item -LiteralPath $bin).VersionInfo.ProductVersion)"}else{$issues+='CAVaultManager.exe missing'}
$log=Join-Path (Join-Path $Settings.PackagesRoot 'Server') 'setup.log'
$rc=Get-Content -LiteralPath $log -ErrorAction SilentlyContinue | Where-Object {$_ -match '^ResultCode='} | Select-Object -Last 1
if($rc -notmatch '^ResultCode=0\s*$'){$issues+="setup.log $rc"}else{$ev+='setup.log ResultCode=0'}
if(Test-Path -LiteralPath (Join-Path (Join-Path $Settings.PackagesRoot 'Server') 'setup.iss')){$issues+='plaintext response file still present'}
[pscustomobject]@{Passed=($issues.Count -eq 0);Message=($issues -join ';');Evidence=$ev}
