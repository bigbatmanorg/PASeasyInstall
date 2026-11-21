# Starts primary services and enables DR using private PACLI input plus independent native proof.
param(
    [Parameter(Mandatory = $true)][hashtable]$Settings,
    [Parameter(Mandatory = $true)][string]$AdminPassword,
    [Parameter(Mandatory = $true)][string]$DRPassword
)
# PAEASY_INCLUDE_VAULT_PACLI
$ErrorActionPreference = 'Stop'
# Validate both literals before service startup, not after a partial configuration change.
$null = New-PAPacliSecretStatement UPDATEUSER 1 @{DESTUSER = 'DR'; DISABLED = 'NO'; PASSWORD = $DRPassword }
$null = New-PAPacliSecretStatement LOGON 1 @{PASSWORD = $AdminPassword }
$pacli = Join-Path (Join-Path $Settings.PackagesRoot 'PACLI') 'Pacli.exe'
$null = Assert-PAPacliBinary $pacli
foreach ($name in @('PrivateArk Database', 'PrivateArk Server', 'CyberArk Logic Container', 'Cyber-Ark Event Notification Engine')) {
    $service = Get-Service -DisplayName $name -ErrorAction Stop
    Set-Service -Name $service.Name -StartupType Automatic
    if ($service.Status -ne 'Running') { Start-Service -Name $service.Name }
}
$session = $null
try {
    $session = Open-PAPacliVaultSession $pacli $AdminPassword
    $delivery = Invoke-PAPacliSecretCommand -Pacli $pacli -Operation UPDATEUSER -SessionId $session.Id -Values @{
        DESTUSER = 'DR'
        DISABLED = 'NO'
        PASSWORD = $DRPassword
    }
    if ($delivery.Delivered -isnot [bool] -or
        -not $delivery.Delivered -or
        $delivery.ExitCode -ne 0) { throw 'PACLI DR update delivery is unconfirmed' }
    $query = Invoke-PAPacliProcess -Pacli $pacli -Operation USERDETAILS -SessionId $session.Id -Arguments @('DESTUSER=DR', 'OUTPUT(ENCLOSE,NAME,DISABLED)')
    if (-not(Test-PAPacliNativeResult $query) -or
        $query.ExitCode -ne 0 -or
        ([string]$query.Err).Trim() -or
        ([string]$query.Out).Trim() -cne '"DR","NO"') { throw 'PACLI independent DR enabled-state verification failed' }
    $session.Codes.Add('dr-enabled=verified')
} finally { if ($session) { Close-PAPacliVaultSession $session } }
if (-not $session.Closed) { throw 'PAExecUnknown: primary configuration session closure is unconfirmed' }
[pscustomobject]@{
    Changed = $true
    Message = 'primary services running; DR enabled state independently verified'
    Data = @{Pacli = ($session.Codes -join ',') }
}
