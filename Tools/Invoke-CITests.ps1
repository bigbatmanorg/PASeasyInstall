<#
.SYNOPSIS
Runs the CI test set: Tools\Check-Modular.ps1, then every Tests\*.Tests.ps1 except those listed in Tests\ci-exclude.txt.
.DESCRIPTION
Used by .github/workflows/ci.yml and release.yml on Windows PowerShell 5.1. Needs Pester 5 and NativeHTMLKit.UI.
Writes NUnit XML to -ResultPath and exits 1 when any test fails.
.EXAMPLE
.\Tools\Invoke-CITests.ps1 -ResultPath .\test-results.xml
#>
[CmdletBinding()]param([string]$ResultPath='test-results.xml')
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
Set-Location $repo
& (Join-Path $repo 'Tools\Check-Modular.ps1') 3>$null
Import-Module Pester -MinimumVersion 5.5.0 -Force
$exclude=@(Get-Content (Join-Path $repo 'Tests\ci-exclude.txt')|Where-Object {$_ -and -not $_.TrimStart().StartsWith('#')}|ForEach-Object {($_ -split '\|')[0].Trim()})
$files=@(Get-ChildItem (Join-Path $repo 'Tests') -Filter '*.Tests.ps1'|Where-Object {$exclude -notcontains $_.Name}|ForEach-Object FullName)
Write-Host "Running $($files.Count) test files; excluded: $($exclude -join ', ')"
$c=New-PesterConfiguration
$c.Run.Path=$files;$c.Run.PassThru=$true;$c.Output.Verbosity='Normal'
$c.TestResult.Enabled=$true;$c.TestResult.OutputFormat='NUnitXml';$c.TestResult.OutputPath=[IO.Path]::GetFullPath($ResultPath)
$r=Invoke-Pester -Configuration $c
Write-Host "Passed $($r.PassedCount), failed $($r.FailedCount), skipped $($r.SkippedCount)"
if($r.FailedCount -gt 0){exit 1}
