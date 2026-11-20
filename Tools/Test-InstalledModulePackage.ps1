<#
.SYNOPSIS
Checks an installed PASeasyInstall package (Install-Module or portable layout) from a fresh process.
.DESCRIPTION
Run it in a NEW powershell.exe whose PSModulePath sees only the package under test (and NativeHTMLKit).
It checks:
  - the expected version is found and imports;
  - NativeHTMLKit.UI (a required dependency) loads with it;
  - exactly the public commands are exported, and nothing PTA-related;
  - every public command has a synopsis and at least one example;
  - optionally, Invoke-PASInstall -PlanOnly on a sample configuration (contacts no server).
It writes a JSON proof to -OutputPath and throws on the first failed check.
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Tools\Test-InstalledModulePackage.ps1 -ExpectedVersion 1.0.0-rc1 -OutputPath C:\Temp\probe.json
.EXAMPLE
.\Tools\Test-InstalledModulePackage.ps1 -ExpectedVersion 1.0.0-rc1 -OutputPath .\probe.json -SampleConfig .\Samples\lab.json
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ExpectedVersion,[Parameter(Mandatory)][string]$OutputPath,[string]$SampleConfig='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$expected=@('Start-PASInstall','Invoke-PASInstall','New-PASDeploymentConfiguration','Get-PASMediaInventory',
    'Get-PASMediaSelection','Test-PASEnvironment','Get-PASEnvironmentPlan','Save-PASEnvironment','Start-PASEnvironment',
    'Get-PASEnvironmentSnapshot','Get-PASEnvironmentEvents','Get-PASStageCatalog','Resume-PASDeployment',
    'Test-PASEnvironmentHealth','Export-PASRunData')
$proof=[ordered]@{schemaVersion=2;checkedUtc=[DateTime]::UtcNow.ToString('o');powershell=$PSVersionTable.PSVersion.ToString();
    edition=$PSVersionTable.PSEdition;expectedVersion=$ExpectedVersion;checks=[ordered]@{};passed=$false}
function Pass([string]$Name,$Value){$proof.checks[$Name]=$Value}
try{
    if(Get-Module PASeasyInstall,PASeasyInstall.*){throw 'Run this probe in a fresh process (PASeasyInstall is already imported)'}
    $available=@(Get-Module PASeasyInstall -ListAvailable)
    if(-not $available.Count){throw 'PASeasyInstall is not installed or not on PSModulePath'}
    $match=@($available|Where-Object {
        $pre=if($_.PrivateData -and $_.PrivateData['PSData']){[string]$_.PrivateData['PSData']['Prerelease']}else{''}
        ([string]$_.Version+$(if($pre){'-'+$pre}else{''})) -eq $ExpectedVersion})
    if(-not $match.Count){throw ("Expected $ExpectedVersion; found: "+(($available|ForEach-Object {[string]$_.Version}) -join ', '))}
    Pass 'installedAt' $match[0].ModuleBase
    Import-Module $match[0].Path -ErrorAction Stop
    $ui=Get-Module NativeHTMLKit.UI
    if(-not $ui){throw 'NativeHTMLKit.UI did not load as a required module'}
    Pass 'nativeHtmlKitUI' ([string]$ui.Version+' '+$ui.ModuleBase)
    $exported=@((Get-Command -Module PASeasyInstall).Name|Sort-Object)
    $missing=@($expected|Where-Object {$exported -notcontains $_})
    $extra=@($exported|Where-Object {$expected -notcontains $_})
    if($missing.Count -or $extra.Count){throw ("Exported command mismatch. Missing: "+($missing -join ',')+' Extra: '+($extra -join ','))}
    if(@($exported|Where-Object {$_ -match 'PTA'}).Count){throw 'PTA commands must not be exported in this release'}
    Pass 'exportedCommands' $exported
    $helpIssues=@()
    foreach($name in $expected){
        $h=Get-Help $name -Full -ErrorAction Stop
        $examples=@()
        if($h.PSObject.Properties['examples'] -and $h.examples){$examples=@($h.examples.example)}
        if(-not ([string]$h.Synopsis).Trim() -or ([string]$h.Synopsis).Trim() -like "$name *" ){$helpIssues+="$name has no synopsis"}
        if(-not $examples.Count){$helpIssues+="$name has no example"}
    }
    if($helpIssues.Count){throw ('Help incomplete: '+($helpIssues -join '; '))}
    Pass 'helpComplete' $true
    $about=Get-Help about_PASeasyInstall -ErrorAction SilentlyContinue
    Pass 'aboutHelp' ([bool]$about)
    if(@(Get-PASStageCatalog -Component Vault).Count -lt 5){throw 'Stage catalog for Vault is unexpectedly small'}
    Pass 'stageCatalog' $true
    if($SampleConfig){
        $plan=Invoke-PASInstall -Config $SampleConfig -PlanOnly 3>$null
        if(-not @($plan.Items).Count){throw 'PlanOnly returned no items'}
        Pass 'planOnly' (@($plan.Items)|ForEach-Object {"$($_.Id) $($_.Type) $($_.Address)"})
    }
    $proof.passed=$true
}catch{
    $proof.error=$_.Exception.Message
    throw
}finally{
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),($proof|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
}
[pscustomobject]$proof
