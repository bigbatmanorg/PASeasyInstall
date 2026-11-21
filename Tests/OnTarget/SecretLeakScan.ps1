# UI-03: searches persisted controller/GUI state for an exact secret value (plain, UTF-16 and Base64 forms).
# Prints only file names and hit counts, never the secret. Exit code = number of files containing it.
#   -CredentialPath: Export-Clixml'd PSCredential whose password is the secret to look for (same-user DPAPI).
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CredentialPath, [string[]]$Path = @(), [string]$Report = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'PASeasyInstall/PASeasyInstall.psd1') -Force
$secret = (Import-Clixml -LiteralPath $CredentialPath).GetNetworkCredential().Password
if ($secret.Length -lt 6) { throw 'Refusing to scan for a secret shorter than 6 characters (too many false positives)' }
$data = Get-PASDataRoot
$targets = @($data, (Join-Path $env:APPDATA 'UI4ME\org.paseasy.install')) + $Path
$needles = @(
    [Text.Encoding]::UTF8.GetBytes($secret),
    [Text.Encoding]::Unicode.GetBytes($secret),
    [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($secret))),
    [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($secret))))
function Find-Bytes([byte[]]$Hay, [byte[]]$Needle) {
    for ($i = 0; $i -le $Hay.Length - $Needle.Length; $i++) {
        if ($Hay[$i] -ne $Needle[0]) { continue }
        $ok = $true
        for ($j = 1; $j -lt $Needle.Length; $j++) {
            if ($Hay[$i + $j] -ne $Needle[$j]) {
                $ok = $false
                break
            }
        }
        if ($ok) { return $true }
    }
    return $false
}
$scanned = 0
$hits = @()
foreach ($t in $targets) {
    if (-not $t -or -not (Test-Path -LiteralPath $t)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $t -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        # Vendor media caches are byte-identical copies of licensed archives, not app output.
        if ($f.FullName -match '\\(MediaCache|MediaAssets)\\' -or $f.Length -gt 50MB) { continue }
        $scanned++
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        foreach ($n in $needles) {
            if (Find-Bytes $bytes $n) {
                $hits += $f.FullName
                break
            }
        }
    }
}
$secret = $null
$lines = @("Secret leak scan $(Get-Date -Format o): scanned $scanned files under: $($targets -join '; ')",
    "Files containing the secret (UTF-8/UTF-16/Base64): $($hits.Count)") + @($hits | ForEach-Object { "  HIT $_" })
$lines | ForEach-Object { Write-Output $_ }
if ($Report) { $lines | Set-Content -LiteralPath $Report }
exit $hits.Count
