param([Parameter(Mandatory = $true)][hashtable]$Settings)
$issues = @()
$ev = @()
foreach ($p in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86', 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\12.0\VC\Runtimes\x86')) {
    $v = Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue
    if (-not $v -or $v.Installed -ne 1) { $issues += "missing $p" }else { $ev += "$($p.Split('\')[-3])/$($p.Split('\')[-1]) $($v.Version)" }
}
$r = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction SilentlyContinue).Release
if ($r -lt 528040) { $issues += ".NET 4.8 missing ($r)" }else { $ev += ".NET release $r" }
[pscustomobject]@{ Passed = ($issues.Count -eq 0); Message = ($issues -join ';'); Evidence = $ev }
