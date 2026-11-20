param([Parameter(Mandatory = $true)][hashtable]$Settings, [ValidateSet('Primary', 'DR')][string]$Role = 'Primary')
# PAEASY_INCLUDE_VAULT_WORKSPACE
$ErrorActionPreference = 'Stop'
$paths = @(Get-PASeasyVaultWorkspacePaths $Settings)
$changed = @($paths | Where-Object { -not(Test-Path -LiteralPath $_) }).Count -gt 0
Protect-PASeasyVaultWorkspace $Settings
# No outbound exception is needed: the PADR service maintains its own scoped rules (CYBERARK_RULE_PADR_SERVER,
# outbound TCP 1858 to the configured primary only), observed on hardened DR Vaults.
$outbound = @()
$policy = [ordered]@{
    schemaVersion = 1; Role = $Role
    ControllerAddress = [string]$Settings.Management.ControllerAddress
    AllowedTargetIPs = @([string]$Settings.PrimaryIP, [string]$Settings.DRIP)
    WinRMPort = [int]$Settings.Management.WinRMPort
    Endpoint = [string]$Settings.Management.Endpoint
    User = [string]$Settings.Management.User
    Outbound = $outbound
}
$file = Join-Path $Settings.AutomationRoot 'management-policy.json'
Write-PASeasyVaultOwnedFile $file ([Text.Encoding]::UTF8.GetBytes(($policy | ConvertTo-Json -Depth 6)))
[pscustomobject]@{
    Changed = $changed
    Message = "paths ready; management policy limits WinRM to $($policy.ControllerAddress)"
}
