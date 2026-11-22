# After the restart that follows the vendor hardening. Windows can switch its update services back on while a
# hardened server restarts (seen on 2026-11-22: "Windows Update" disabled -> demand start and "Background
# Intelligent Transfer Service" disabled -> auto start, changed by SYSTEM two seconds after the restart was
# requested). The vendor hardening disables both, so they are disabled again here. Nothing else is touched:
# every other service of the vendor's list is only measured by Verify-Hardening.ps1.
param([Parameter(Mandatory = $true)][hashtable]$Settings)
$ErrorActionPreference = 'Stop'
if ($Settings.Hardening.Contains('Skip') -and [bool]$Settings.Hardening.Skip) {
    # Lab configuration with -SkipHardening: the Vault server stays as Windows and the Vault installer left it.
    return [pscustomobject]@{ Changed = $false; Message = 'Hardening skipped by the lab configuration (SkipHardening)' }
}
$restored = @()
foreach ($name in @('wuauserv', 'BITS')) {
    $service = Get-Service -Name $name -ErrorAction SilentlyContinue
    if (-not $service -or $service.StartType -eq 'Disabled') {
        continue
    }
    $was = [string]$service.StartType
    if ($service.Status -ne 'Stopped') {
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
    }
    Set-Service -Name $name -StartupType Disabled
    $restored += "$name (was $was)"
}
if ($restored.Count) {
    [pscustomobject]@{ Changed = $true; Message = 'Windows had switched these services back on during the restart; disabled again: ' + ($restored -join ', ') }
} else {
    [pscustomobject]@{ Changed = $false; Message = 'the update services are still disabled after the restart' }
}
