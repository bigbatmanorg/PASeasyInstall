# Shared Core implementation: original durable engine, transport, security and journals.
# Component recipes are resolved from sibling independently importable modules.
Set-StrictMode -Version 2.0
$script:PASRoot=$PSScriptRoot
$ErrorActionPreference='Stop'
foreach($part in @(
  'Private/Foundation/ModulePaths.ps1',
  'Private/Foundation/Paths.ps1',
  'Recipes/WindowsComponent/Archive.ps1',
  'Private/Foundation/Profiles.ps1',
  'Private/Foundation/Media.ps1',
  'Private/Foundation/Secrets.ps1',
  'Private/Engine/Init.ps1',
  'Private/V2/Configuration.ps1',
  'Private/V2/Planning.ps1',
  'Private/V2/Coordination.ps1',
  'Private/V2/PTASyslog.ps1',
  'Private/V2/Run.ps1',
  'Private/V2/Health.ps1',
  'Private/V2/Diagnostics.ps1',
  'Private/V2/Events.ps1'
)){
    $file=Join-Path $script:PASRoot $part
    if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "Missing PASeasyInstall source file: $file"}
    . $file
}
Export-ModuleMember -Function @(
  'Initialize-PASeasyController','New-PASeasyConfig','Test-PASeasyConfig','Get-PASeasyPlan',
  'Start-PASeasyDeployment','Resume-PASeasyDeployment',
  'Get-PASeasyRun','Get-PASeasyRuns','Get-PASeasyLog','Get-PASeasyLogSources',
  'Get-PASeasyComponentStatus','Test-PASeasyDeployment',
  'Get-PASDeploymentEvents','Get-PASDeploymentSnapshot'
)
