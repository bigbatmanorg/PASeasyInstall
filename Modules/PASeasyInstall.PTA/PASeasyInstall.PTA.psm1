# PASeasyInstall.PTA. Independent component API; NativeHTMLKit is never imported here.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$core=Join-Path $root 'PASeasyInstall.Core/PASeasyInstall.Core.psd1'
if(-not(Test-Path -LiteralPath $core -PathType Leaf)){throw 'PASeasyInstall.Core is required'}
Import-Module $core -ErrorAction Stop

function New-PASPTAConfiguration {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$TargetAddress,
        [Parameter(Mandatory)][string]$VaultAddress,[Parameter(Mandatory)][string]$MediaZip,
        [string]$Environment='MyPAM',[string]$Username='root',[hashtable]$Options=@{})
    $c=New-PASeasyConfig -Template ExistingVault -Path 'template.json' -WhatIf -Force
    $c.name=$Environment.Trim();$c.mediaRoot='';$c.controllerAddress=''
    $c.vault.address=$VaultAddress.Trim();$c.vault.existing=$true
    $c.components=@(@{id='pta';type='PTA';host='pta01';variant='Standard';media=$MediaZip;options=$Options.Clone()})
    $c.hosts=@{'pta01'=@{address=$TargetAddress.Trim();os='Linux';user=$Username.Trim();credentialRef='pta01'}}
    $c.activeDirectory.mode='None';$c.activeDirectory.join=@()
    $validation=Test-PASeasyConfig -Configuration $c
    if(-not $validation.Valid){throw ('Invalid PTA configuration: '+($validation.Issues -join '; '))}
    return $validation.Configuration
}
function Invoke-PASPTA {
    [CmdletBinding(SupportsShouldProcess=$true)]param([string]$Config,$Configuration,
        [ValidateSet('All','LocalPreflight')][string]$Stage='All',
        [hashtable]$CredentialMap=@{},[hashtable]$SecretMap=@{},[switch]$PlanOnly)
    $validation=Test-PASeasyConfig -Config $Config -Configuration $Configuration -CheckMedia:($Stage -eq 'LocalPreflight')
    if(-not $validation.Valid){throw ($validation.Issues -join '; ')}
    $types=@($validation.Configuration.components|ForEach-Object {[string]$_.type})
    if($types.Count -ne 1 -or $types[0] -ne 'PTA'){throw 'This command accepts only one PTA component, not a multi-component plan'}
    if($Stage -eq 'LocalPreflight'){return $validation}
    if($PlanOnly){return (Get-PASeasyPlan -Configuration $validation.Configuration)}
    if($PSCmdlet.ShouldProcess($validation.Configuration.name,'Deploy PTA component')){
        return (Start-PASeasyDeployment -Configuration $validation.Configuration -CredentialMap $CredentialMap -SecretMap $SecretMap -Confirm:$false)
    }
}
function Get-PASPTAStages {
    [CmdletBinding()]param()
    $names=@('LocalPreflight','management','media-upload','preflight','extract','prerequisites','install','configuretls','register','harden','verify')
    foreach($stage in $names){[pscustomobject]@{Component='PTA';Stage=$stage;ReadOnly=($stage -eq 'LocalPreflight');TargetExecutionQualified=$false}}
}

Export-ModuleMember -Function @('New-PASPTAConfiguration','Get-PASPTAStages','Invoke-PASPTA')
