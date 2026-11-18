# Optional composition layer. The component modules and Core work without this module.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:PASModulesRoot=Split-Path -Parent $PSScriptRoot
function Import-PASComponentModule {
    param([ValidateSet('Core','Vault','DR','PVWA','CPM','PSM','PSMP','PTA','AD')][string]$Name)
    $file=Join-Path (Join-Path $script:PASModulesRoot ('PASeasyInstall.'+$Name)) ('PASeasyInstall.'+$Name+'.psd1')
    if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw "PASeasyInstall.$Name is not installed beside the orchestrator"}
    Import-Module $file -ErrorAction Stop
}
Import-PASComponentModule Core
foreach($private in @('MediaInventory.ps1','Composition.ps1','Fleet.ps1')){. (Join-Path (Join-Path $PSScriptRoot 'Private') $private)}

function New-PASFreshEnvironment {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$PrimaryIP,
        [Parameter(Mandatory)][string]$ControllerIP,[Parameter(Mandatory)][string]$MediaRoot,
        [string]$Environment='MyPAM',[string]$Username='Administrator',
        [switch]$WithDR,[string]$DRIP='',
        [string]$LicenseFile='',[string]$PublicRecoveryKey='',
        [string]$ServerZip='',[string]$PACLIZip='',[string]$DisasterRecoveryZip='',
        [ValidateSet('Secure','Lab')][string]$SecurityProfile='Secure')
    Import-PASComponentModule Vault
    if($DRIP -and -not $WithDR){throw 'DR IP supplied without selecting a Primary + DR deployment'}
    if($WithDR -and -not $DRIP){throw 'Primary + DR setup requires a DR target IP address'}
    $c=New-PASVaultConfiguration -PrimaryIP $PrimaryIP -ControllerIP $ControllerIP -MediaRoot $MediaRoot `
        -Environment $Environment -Username $Username -LicenseFile $LicenseFile `
        -PublicRecoveryKey $PublicRecoveryKey -ServerZip $ServerZip -PACLIZip $PACLIZip -SecurityProfile $SecurityProfile
    if($WithDR){
        Import-PASComponentModule DR
        $c=Add-PASDRConfiguration -Configuration $c -DRIP $DRIP -Username $Username -DisasterRecoveryZip $DisasterRecoveryZip
    }
    return $c
}
function New-PASExistingVaultComponent {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateSet('PVWA','CPM','PSM','PSMP')][string]$Component,
        [Parameter(Mandatory)][string]$TargetAddress,[Parameter(Mandatory)][string]$VaultAddress,
        [Parameter(Mandatory)][string]$MediaZip,[string]$Environment='MyPAM',[string]$Username='',
        [hashtable]$Options=@{})
    Import-PASComponentModule $Component
    if(-not $Username){$Username=if($Component -in @('PTA','PSMP')){'root'}else{'Administrator'}}
    $args=@{TargetAddress=$TargetAddress;VaultAddress=$VaultAddress;MediaZip=$MediaZip;Environment=$Environment;Username=$Username;Options=$Options}
    switch($Component){
        'PVWA'{return (New-PASPVWAConfiguration @args)}
        'CPM'{return (New-PASCPMConfiguration @args)}
        'PSM'{return (New-PASPSMConfiguration @args)}
        'PSMP'{return (New-PASPSMPConfiguration @args)}
        'PTA'{return (New-PASPTAConfiguration @args)}
    }
}
function Assert-PASDeploymentTopology {
    param($Configuration)
    $components=@($Configuration.components)
    $dr=@($components|Where-Object {$_.type -eq 'DRVault'})
    $primary=@($components|Where-Object {$_.type -eq 'Vault'})
    if($dr.Count -and ($dr.Count -ne 1 -or $primary.Count -ne 1 -or $Configuration.vault.existing)){
        throw 'DR is only supported with a new Primary Vault in the same deployment; attaching DR to existing Vault is not supported'
    }
}
function Test-PASEnvironment {
    [CmdletBinding()]param([string]$Config,$Configuration,[switch]$CheckMedia)
    $valid=Test-PASeasyConfig -Config $Config -Configuration $Configuration -CheckMedia:$CheckMedia
    if($valid.Configuration){
        Assert-PASDeploymentTopology $valid.Configuration
        $rules=Test-PASOrchestratorRules $valid.Configuration
        if($rules.Issues.Count -or $rules.Warnings.Count){
            $issues=@($valid.Issues)+@($rules.Issues);$warnings=@($valid.Warnings)+@($rules.Warnings)
            $valid=[pscustomobject]@{Valid=($issues.Count -eq 0);Issues=@($issues);Warnings=@($warnings);Configuration=$valid.Configuration}
        }
    }
    return $valid
}
function Get-PASEnvironmentPlan {
    [CmdletBinding()]param([string]$Config,$Configuration,[switch]$ResolveMedia)
    $valid=Test-PASEnvironment -Config $Config -Configuration $Configuration
    if(-not $valid.Valid){throw ('Configuration incomplete: '+($valid.Issues -join '; '))}
    return (Add-PASPlanDetail -Plan (Get-PASeasyPlan -Configuration $valid.Configuration -ResolveMedia:$ResolveMedia) -Configuration $valid.Configuration)
}
function Save-PASEnvironment {
    [CmdletBinding(SupportsShouldProcess=$true)]param([Parameter(Mandatory)]$Configuration,[Parameter(Mandatory)][string]$Path,[switch]$Force)
    $valid=Test-PASEnvironment -Configuration $Configuration
    if(-not $valid.Valid){throw ('Configuration incomplete: '+($valid.Issues -join '; '))}
    $full=[IO.Path]::GetFullPath($Path)
    if(Test-Path -LiteralPath $full -PathType Leaf){if(-not $Force){throw "Configuration already exists: $full. Reopen or explicitly use -Force."}}
    if($PSCmdlet.ShouldProcess($full,'Save deployment configuration')){
        $dir=[IO.Path]::GetDirectoryName($full)
        if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
        $tmp=$full+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
        try{
            [IO.File]::WriteAllText($tmp,($valid.Configuration|ConvertTo-Json -Depth 60),(New-Object Text.UTF8Encoding($false)))
            if(Test-Path -LiteralPath $full){[IO.File]::Replace($tmp,$full,[NullString]::Value)}
            else{[IO.File]::Move($tmp,$full)}
        }finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}
        return $full
    }
}
function Start-PASEnvironment {
    [CmdletBinding(SupportsShouldProcess=$true)]param([string]$Config,$Configuration,
        [hashtable]$CredentialMap=@{},[hashtable]$SecretMap=@{},[switch]$PlanOnly)
    $valid=Test-PASEnvironment -Config $Config -Configuration $Configuration -CheckMedia:(!$PlanOnly)
    if(-not $valid.Valid){throw ('Configuration incomplete: '+($valid.Issues -join '; '))}
    if($PlanOnly){return (Get-PASEnvironmentPlan -Configuration $valid.Configuration)}
    if($PSCmdlet.ShouldProcess($valid.Configuration.name,'Start selected component deployment')){
        # Composed configurations (New-PASDeploymentConfiguration) run as a sequential or parallel set
        # of engine runs; a hand-written single configuration keeps the single-run path.
        if($valid.Configuration.Contains('execution')){
            return (Start-PASFleet -Configuration $valid.Configuration -CredentialMap $CredentialMap -SecretMap $SecretMap)
        }
        $creds=ConvertTo-PASControllerCredentialMap $valid.Configuration $CredentialMap
        return (Start-PASeasyDeployment -Configuration $valid.Configuration -CredentialMap $creds -SecretMap $SecretMap -Confirm:$false)
    }
}
function Get-PASEnvironmentSnapshot {
    <# Progress of a deployment started by Start-PASEnvironment (composed deployment or single run).
       Events: TimestampUtc, Component (plan item id), Stage, Event, Level, Status (Running|Complete|
       Failed|Warning|Info), Message. Never a guessed percentage. #>
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunId,[int]$Tail=150)
    if(Test-PASFleetId $RunId){return (Get-PASFleetSnapshot -FleetId $RunId -Tail $Tail)}
    $snap=Get-PASDeploymentSnapshot -RunId $RunId -Tail $Tail
    foreach($e in @($snap.Events)){$e.Component=ConvertTo-PASUIComponentId $e.Component}
    if($snap.CurrentComponent){$snap.CurrentComponent=ConvertTo-PASUIComponentId $snap.CurrentComponent}
    return $snap
}
function Get-PASEnvironmentEvents {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$RunId,[int]$Tail=150)
    return @((Get-PASEnvironmentSnapshot -RunId $RunId -Tail $Tail).Events)
}
function Get-PASStageCatalog {
    [CmdletBinding()]param([Parameter(Mandatory)][ValidateSet('Vault','DR','PVWA','CPM','PSM','PSMP','AD')][string]$Component)
    Import-PASComponentModule $Component
    switch($Component){
        'Vault' {return @(Get-PASVaultStages)}
        'DR' {return @(Get-PASDRStages)}
        'PVWA' {return @(Get-PASPVWAStages)}
        'CPM' {return @(Get-PASCPMStages)}
        'PSM' {return @(Get-PASPSMStages)}
        'PSMP' {return @(Get-PASPSMPStages)}
        'PTA' {return @(Get-PASPTAStages)}
        'AD' {return @(Get-PASADStages)}
    }
}
Export-ModuleMember -Function @('New-PASFreshEnvironment','New-PASExistingVaultComponent',
    'Get-PASMediaInventory','Get-PASMediaSelection','New-PASDeploymentConfiguration',
    'Test-PASEnvironment','Get-PASEnvironmentPlan','Save-PASEnvironment','Start-PASEnvironment',
    'Get-PASEnvironmentSnapshot','Get-PASEnvironmentEvents','Get-PASStageCatalog')
