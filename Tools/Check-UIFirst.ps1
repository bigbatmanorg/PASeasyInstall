<#
.SYNOPSIS
Non-destructive static and contract validation for the PASeasyInstall GUI-first skeleton.
#>
[CmdletBinding()]param([switch]$RunPester)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$files=@((Join-Path $root 'Start-PASeasyInstall.ps1'))
$files+=@(Get-ChildItem -LiteralPath (Join-Path $root 'PASeasyInstall') -Recurse -File |
    Where-Object {$_.Extension -in @('.ps1','.psm1','.psd1')} | Select-Object -ExpandProperty FullName)
$files+=@(Get-ChildItem -LiteralPath (Join-Path $root 'Tests') -Filter '*.ps1' -File |
    Select-Object -ExpandProperty FullName)
$errors=@()
foreach($file in $files){
    $tokens=$null;$parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$parseErrors)
    $errors+=@($parseErrors|ForEach-Object {"$file`:$($_.Extent.StartLineNumber) $($_.Message)"})
}
if($errors.Count){throw "PowerShell parser found errors:`n$($errors -join "`n")"}
Import-Module (Join-Path $root 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force -ErrorAction Stop
$sample=New-PASeasyConfig -Template Vault -Path (Join-Path $env:TEMP 'paeasy-ui-first-parse.json') -WhatIf
$validation=Test-PASeasyConfig -Configuration $sample
if(-not $validation.Valid){throw "Module contract failed: $($validation.Issues -join '; ')"}
"PASS: $($files.Count) PowerShell source/test/launcher files parsed; module import and planner contract available. No target writes."
if($RunPester){
    if(-not(Get-Command Invoke-Pester -ErrorAction SilentlyContinue)){throw 'Pester is not installed'}
    $testPaths=@('UIConfiguration.Tests.ps1','UICredentials.Tests.ps1','UIOperations.Tests.ps1','UIFirstWorkflow.Tests.ps1')|
        ForEach-Object {Join-Path (Join-Path $root 'Tests') $_}
    $result=Invoke-Pester -Path $testPaths -PassThru
    if($result.FailedCount -gt 0){throw "UI-first Pester suite has $($result.FailedCount) failures"}
}
