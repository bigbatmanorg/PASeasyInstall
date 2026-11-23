# After a reboot, waits (read-only) until all primary Vault services run and the Vault logged ITADB313I
# ("Server ... is up") after the latest boot.
# AdminPassword is accepted because the step shares its inputs with Verify-Primary (PACLI login); unused here.
param([Parameter(Mandatory = $true)][hashtable]$Settings, [int]$Minutes = 15, [string]$AdminPassword)
$ErrorActionPreference = 'Stop'
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$italog = Join-Path $Settings.InstallRoot 'Server\Logs\italog.log'
$deadline = (Get-Date).AddMinutes($Minutes)
$last = ''
while ((Get-Date) -lt $deadline) {
    $down = @(foreach ($n in @('PrivateArk Database', 'PrivateArk Server', 'CyberArk Logic Container', 'Cyber-Ark Event Notification Engine')) {
            $s = Get-Service -DisplayName $n -ErrorAction SilentlyContinue
            if ($s -and $s.Status -eq 'Stopped' -and $s.StartType -ne 'Disabled') {
                # Two of the Vault services are "automatic (delayed start)": Windows starts them about two
                # minutes after the restart. Nothing has to wait for that: start them now.
                try { Start-Service -InputObject $s -ErrorAction Stop } catch { Write-Verbose "not started yet: $n" }
                $s = Get-Service -DisplayName $n -ErrorAction SilentlyContinue
            }
            if (-not $s -or
                $s.Status -ne 'Running') { $n }
        })
    $up = $null
    if (Test-Path -LiteralPath $italog) {
        foreach ($l in @(Get-Content -LiteralPath $italog -Tail 3000 | Where-Object { $_ -match 'ITADB313I Server .* is up' })) {
            $m = [regex]::Match($l, '^(\d\d/\d\d/\d{4})\s+(\d\d:\d\d:\d\d)')
            if ($m.Success) {
                $t = [datetime]::ParseExact($m.Groups[1].Value + ' ' + $m.Groups[2].Value, 'dd/MM/yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
                if ($t -ge $boot.AddSeconds(-5)) { $up = $l.Trim() }
            }
        }
    }
    if ($down.Count -eq 0 -and $up) {
        [pscustomobject]@{
            Changed = $false
            Message = "Vault up since boot $($boot.ToString('s')): $up"
        }
        return
    }
    $last = "waiting: down=[$($down -join ',')] upAfterBoot=$([bool]$up)"
    Start-Sleep -Seconds 5
}
throw "Primary Vault not ready within $Minutes minutes ($last)"
