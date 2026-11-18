# Pure read-only tests, safe in Windows PowerShell 5.1. No vendor install and no UI host.
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $root 'Modules'
foreach($file in @(Get-ChildItem -LiteralPath $modules -Recurse -File|Where-Object {$_.Extension -in @('.ps1','.psm1','.psd1')})){
    if($file.Name.EndsWith('.disabled')){continue}
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors){throw ('Parse failed '+$file.FullName+': '+(($errors|ForEach-Object {$_.Message}) -join '; '))}
}
foreach($name in @('Core','Vault','DR','PVWA','CPM','PSM','PSMP','PTA','AD','Orchestrator','UI')){
    Test-ModuleManifest (Join-Path $modules ('PASeasyInstall.'+$name+'/PASeasyInstall.'+$name+'.psd1')) -ErrorAction Stop|Out-Null
}
Import-Module (Join-Path $modules 'PASeasyInstall.Orchestrator/PASeasyInstall.Orchestrator.psd1') -Force
$c=New-PASFreshEnvironment -Environment TestPAM -PrimaryIP '192.0.2.11' -ControllerIP '192.0.2.10' -MediaRoot 'C:\Media'
if(@($c.components).Count -ne 1){throw 'Primary setup failed'}
if(-not (Test-PASEnvironment -Configuration $c).Valid){throw 'Primary validation failed'}
$p=Get-PASEnvironmentPlan -Configuration $c
if(@($p.Items).Count -ne 1){throw 'Primary planning failed'}
$d=New-PASFreshEnvironment -Environment TestDR -PrimaryIP '192.0.2.11' -DRIP '192.0.2.12' -WithDR -ControllerIP '192.0.2.10' -MediaRoot 'C:\Media'
if(@($d.components).Count -ne 2){throw 'Primary+DR setup failed'}
if(-not (Test-PASEnvironment -Configuration $d).Valid){throw 'Primary+DR validation failed'}
try{$bad=New-PASFreshEnvironment -PrimaryIP '192.0.2.11' -ControllerIP '192.0.2.10' -MediaRoot 'C:\Media' -DRIP '192.0.2.12';throw 'DR constraint not enforced'}catch{if($_.Exception.Message -match 'not enforced'){throw}}
Write-Output 'PASS: modular parser, manifests, Primary, paired DR and plan. No live vendor operations.'
