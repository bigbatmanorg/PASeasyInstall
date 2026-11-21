param([Parameter(Mandatory = $true)][hashtable]$Settings)
$issues = @()
$ev = @()
# PAEASY_INCLUDE_VAULT_PADR
try {
    Assert-PASeasyPadrManualStandby $Settings
    $ev += 'EnableFailover=No; FailoverMode=No; primary address and standby services verified'
} catch { $issues += $_.Exception.Message }
$s = Get-Service -DisplayName 'CyberArk Vault Disaster Recovery' -ErrorAction SilentlyContinue
if (-not $s) { $issues += 'PADR service missing' }else {
    $ev += "PADR service $($s.Status)/$($s.StartType)"
    if (-not(($s.Status -eq 'Stopped' -and
                $s.StartType -eq 'Manual') -or
            ($s.Status -eq 'Running' -and
            $s.StartType -eq 'Automatic'))) { $issues += 'PADR service is neither stopped/manual installation boundary nor running/automatic configured standby' }
}
$conf = Join-Path $Settings.InstallRoot 'PADR\Conf'
$addr = Get-Content -LiteralPath (Join-Path $conf 'Vault.ini') -ErrorAction SilentlyContinue |
    Where-Object { $_ -match '^ADDRESS=' } |
    Select-Object -First 1
if ($addr -ne ('ADDRESS=' + $Settings.PrimaryIP)) { $issues += "Vault.ini $addr" }else { $ev += $addr }
if (Test-Path -LiteralPath (Join-Path (Join-Path $Settings.PackagesRoot 'Disaster Recovery') 'setup.iss')) { $issues += 'plaintext response file still present' }
[pscustomobject]@{Passed = ($issues.Count -eq 0); Message = ($issues -join ';'); Evidence = $ev }
