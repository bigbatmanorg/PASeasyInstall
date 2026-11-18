# Offline public API probe. Builder invokes this in a new powershell.exe process.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ConsumerRoot,[Parameter(Mandatory)][version]$ExpectedVersion,
      [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSourceDigest,
      [Parameter(Mandatory)][string]$SourceFileInventory,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Packaging.Common.ps1')
if($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop'){throw 'Installed-consumer qualification requires Windows PowerShell5.1'}
$consumer=Assert-PASeasyPackageLocalPath $ConsumerRoot
$output=Assert-PASeasyPackageLocalPath $OutputPath
if(Test-Path $output){throw 'Consumer proof already exists; preserve prior evidence'}
if(Get-Module PASeasyInstall,NativeHTMLKit*,PSSteps){throw 'Probe requires a fresh process without imported development modules'}
$env:PSModulePath=$consumer+';'+(Join-Path $PSHOME 'Modules')
$nativeVisible=@(Get-Module NativeHTMLKit* -ListAvailable).Count
$psstepsVisible=@(Get-Module PSSteps -ListAvailable).Count
if($nativeVisible -or $psstepsVisible){throw 'Dependency isolation failed; optional/forbidden SDK remains visible'}
Assert-PASeasyPackageTrustedPath $consumer
Assert-PASeasyPackageTrustedPath $SourceFileInventory
Assert-PASeasyPackageTrustedPath (Split-Path $output -Parent)
$base=Join-Path (Join-Path $consumer 'PASeasyInstall') ([string]$ExpectedVersion)
Assert-PASeasyPackageTrustedPath $base
$inventory=Get-Content -LiteralPath $SourceFileInventory -Raw -Encoding UTF8|ConvertFrom-Json
if($inventory.SchemaVersion -ne 1 -or [string]$inventory.SourceDigest -ine $ExpectedSourceDigest -or [string]$inventory.Version -ne [string]$ExpectedVersion){throw 'Invalid expected package source inventory'}
if([string]$inventory.InventorySHA256 -ine (Get-PASeasyPackageInventoryDigest @($inventory.Files))){throw 'Package source inventory digest is inconsistent'}
$seen=@{}
foreach($file in @($inventory.Files)){
    $relative=[string]$file.Relative
    if(-not(Test-PASeasyPackageSourcePath ('PASeasyInstall/'+$relative)) -or $seen.ContainsKey($relative)){throw 'Invalid/duplicate expected installed source path'}
    $seen[$relative]=$true
    $path=Join-Path $base $relative
    Assert-PASeasyPackageTrustedPath $path
    if(-not(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-Item -LiteralPath $path).Length -ne [long]$file.Bytes -or (Get-FileHash $path -Algorithm SHA256).Hash -ine [string]$file.SHA256){throw 'Saved package source bytes differ from the committed export'}
}
foreach($file in @(Get-ChildItem -LiteralPath $base -Recurse -File)){
    $relative=$file.FullName.Substring($base.Length).Replace('\','/').TrimStart('/')
    if(-not $seen.ContainsKey($relative) -and $relative -ne 'PSGetModuleInfo.xml'){throw 'Installed package contains an unexpected file'}
}
$module=Import-Module PASeasyInstall -RequiredVersion $ExpectedVersion -PassThru -Force -ErrorAction Stop
$base=[IO.Path]::GetFullPath($module.ModuleBase)
if(-not $base.StartsWith($consumer.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Module resolved outside the isolated installed-consumer directory'}
$manifest=Test-ModuleManifest (Join-Path $base 'PASeasyInstall.psd1')
$expected=@('Initialize-PASeasyController','New-PASeasyConfig','Test-PASeasyConfig','Get-PASeasyPlan','Start-PASeasyDeployment','Resume-PASeasyDeployment','Get-PASeasyRun','Get-PASeasyRuns','Get-PASeasyLog','Get-PASeasyLogSources','Get-PASeasyComponentStatus','Test-PASeasyDeployment','Start-PASeasyUI')
$actual=@(Get-Command -Module PASeasyInstall|ForEach-Object Name)
if(@(Compare-Object ($expected|Sort-Object) ($actual|Sort-Object)).Count){throw 'Installed public API differs from the13-command contract'}
if(@($manifest.RequiredModules).Count){throw 'Installed module unexpectedly requires another module'}
$digest=& $module {Get-PASeasySourceDigest}
if($digest -ine $ExpectedSourceDigest){throw 'Installed module source digest differs from the tracked export'}
$plans=@()
foreach($template in @('Vault','VaultDR','FullLab','ExistingVault','DomainJoin')){
    $configuration=New-PASeasyConfig -Template $template -Path (Join-Path (Split-Path $output -Parent) ($template+'-not-written.json')) -WhatIf
    $assessment=Test-PASeasyConfig -Configuration $configuration
    if(-not $assessment.Valid){throw ('Installed sample invalid: '+$template)}
    $plan=Get-PASeasyPlan -Configuration $configuration
    if($plan.SourceDigest -ine $ExpectedSourceDigest){throw 'Installed planner read development source'}
    $plans+=@{Template=$template;Components=@($plan.Items).Count;Joins=@($plan.DomainJoins).Count;SourceDigest=$plan.SourceDigest}
}
$guiDependencyBlocked=$false
try{Start-PASeasyUI}catch{if($_.Exception.Message -match 'NativeHTMLKit.UI is optional and not installed'){$guiDependencyBlocked=$true}else{throw}}
if(-not $guiDependencyBlocked -or @(Get-Module NativeHTMLKit*,PSSteps).Count){throw 'CLI/optional GUI dependency boundary failed'}
$proof=[ordered]@{Passed=$true;PSVersion=[string]$PSVersionTable.PSVersion;ModulePath=$module.Path;Version=[string]$manifest.Version;SourceDigest=$digest;InventorySHA256=[string]$inventory.InventorySHA256;PublicCommands=$actual.Count;NativeSDKVisible=$nativeVisible;NativeSDKImported=@(Get-Module NativeHTMLKit*).Count;PSStepsVisible=$psstepsVisible;PSStepsImported=@(Get-Module PSSteps).Count;GUIUnavailableClearly=$guiDependencyBlocked;Plans=$plans;Scope='Fresh process and isolated installed-module path on existing controller; clean VM and component deployment NotTested';CapturedUtc=[DateTime]::UtcNow.ToString('o')}
Write-PASeasyPackageJson $output $proof
[pscustomobject]$proof
