# Read-only preflight: refuses to start on a host that is not clean or not configured for mandatory hardening.
param([Parameter(Mandatory=$true)][hashtable]$Settings,[ValidateSet('Primary','DR')][string]$Role='Primary')
$ErrorActionPreference='Stop'
$issues=@()
$os=Get-CimInstance Win32_OperatingSystem
if($os.Caption -notmatch 'Windows Server 20(16|19|22)'){$issues+="Unsupported OS for Vault hardening: $($os.Caption)"}
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){$issues+='Administrator privileges required'}
if([string]$Settings.Hardening.Architecture -ne 'StandardVault'){$issues+='Hardening.Architecture must be StandardVault for on-premises Vaults'}
foreach($ip in @($Settings.Management.ControllerAddress,$Settings.PrimaryIP,$Settings.DRIP)){ try{[void][Net.IPAddress]::Parse([string]$ip)}catch{$issues+="Invalid IP address '$ip'"} }
$mine=@(Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object { $_.IPAddress })
$expected=$Settings.PrimaryIP; if($Role -eq 'DR'){$expected=$Settings.DRIP}
if($mine -notcontains $expected){$issues+="This host does not own the configured $Role address $expected (has $($mine -join ','))"}
if(Test-Path -LiteralPath (Join-Path $Settings.InstallRoot 'Server')){$issues+='A Vault Server installation already exists; restore the clean snapshot first'}
$drive=Get-PSDrive -Name ([string]$Settings.DataDrive).TrimEnd(':') -ErrorAction SilentlyContinue
if(-not $drive -or $drive.Free -lt 10GB){$issues+="Less than 10 GB free on data drive $($Settings.DataDrive)"}
if($issues.Count){throw ('Preflight failed: '+($issues -join '; '))}
[pscustomobject]@{Changed=$false;Message="$Role host $env:COMPUTERNAME ($expected) on $($os.Caption) ready";Data=@{Computer=$env:COMPUTERNAME;OS=$os.Caption;Build=$os.BuildNumber}}
