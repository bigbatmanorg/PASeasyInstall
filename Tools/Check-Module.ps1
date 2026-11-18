# Non-invasive static/API smoke test: no VM mutations and no vendor media required.
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$module=Join-Path $root 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1'
$bad=@()
Get-ChildItem -LiteralPath (Join-Path $root 'Modules') -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1','.psd1') } |ForEach-Object {
    $tokens=$null;$parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName,[ref]$tokens,[ref]$parseErrors)
    if($parseErrors){$bad+=@($parseErrors | ForEach-Object{"$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)"})}
}
if($bad.Count){throw "PowerShell parse errors:`n$($bad -join "`n")"}
$manifest=Test-ModuleManifest -Path $module -ErrorAction Stop
Import-Module $module -Force -ErrorAction Stop
Import-Module (Join-Path $root 'Modules/PASeasyInstall.Orchestrator/PASeasyInstall.Orchestrator.psd1') -Force
$sample=New-PASeasyConfig -Template Vault -Path (Join-Path $env:TEMP 'paeasy-smoke-example.json') -WhatIf
$test=Test-PASeasyConfig -Configuration $sample
if(-not $test.Valid){throw "Config smoke failed: $($test.Issues -join '; ')"}
$plan=Get-PASeasyPlan -Configuration $sample
if(@($plan.Items).Count -ne 1 -or $plan.Items[0].Type -ne 'Vault'){throw 'Planner smoke mismatch'}
$exports=@('New-PASeasyConfig','Test-PASeasyConfig','Get-PASeasyPlan','Start-PASeasyDeployment',
 'Resume-PASeasyDeployment','Get-PASeasyRun','Get-PASeasyRuns','Get-PASeasyLog',
 'Get-PASeasyLogSources','Get-PASeasyComponentStatus','Test-PASeasyDeployment')
foreach($name in $exports){if(-not(Get-Command $name -ErrorAction SilentlyContinue)){throw "Missing export: $name"}}
"PASS: PowerShell parsed, Core imported, $($manifest.Version), configuration validated, plan generated one Vault; NO LIVE VM TESTS."
