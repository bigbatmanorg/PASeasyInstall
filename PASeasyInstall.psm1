# PASeasyInstall umbrella module: the public command surface of the package.
# Builds CyberArk PAM self-hosted LABS. Production use is at your own risk. Not affiliated with CyberArk.
#
# Layout (Gallery install, portable ZIP or source checkout):
#   PASeasyInstall.psd1 / .psm1   this module
#   Modules\PASeasyInstall.*      engine (Core), component recipes, Orchestrator and the desktop UI
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:PASPackageRoot=$PSScriptRoot
$script:PASModulesRoot=Join-Path $PSScriptRoot 'Modules'
foreach($name in @('PASeasyInstall.Core','PASeasyInstall.Orchestrator')){
    $manifest=Join-Path (Join-Path $script:PASModulesRoot $name) ($name+'.psd1')
    if(-not(Test-Path -LiteralPath $manifest -PathType Leaf)){throw "PASeasyInstall package is incomplete: $manifest is missing"}
    Import-Module $manifest -ErrorAction Stop
}

function Start-PASeasyInstall {
    <#
    .SYNOPSIS
    Opens the PASeasyInstall desktop: a six-step wizard that builds a CyberArk PAM lab.
    .DESCRIPTION
    The steps are: project and media, what to install, servers, credentials, review plan, and install with
    live progress. Nothing is sent to any server before you press Install on the last step.
    Needs Windows PowerShell 5.1 for installations and NativeHTMLKit.UI, which is installed with this module.
    PASeasyInstall builds labs. Production use is at your own risk.
    .PARAMETER Config
    Optional deployment configuration (JSON) to show.
    .PARAMETER Advanced
    Shows the advanced options.
    .PARAMETER Theme
    v2 (default, dark and compact) or v1 (light).
    .PARAMETER Backend
    Orchestrator (default) runs real installations. Mock simulates plans and installations and never
    contacts a server, which is useful for demos and training.
    .EXAMPLE
    Start-PASeasyInstall
    .EXAMPLE
    Start-PASeasyInstall -Backend Mock
    #>
    [CmdletBinding()]
    param([string]$Config='',[switch]$Advanced,[ValidateSet('v1','v2')][string]$Theme='v2',
        [ValidateSet('Orchestrator','Mock')][string]$Backend='Orchestrator')
    $ui=Join-Path (Join-Path $script:PASModulesRoot 'PASeasyInstall.UI') 'PASeasyInstall.UI.psd1'
    Import-Module $ui -ErrorAction Stop
    if($Config){$Config=(Resolve-Path -LiteralPath $Config).ProviderPath}
    Start-PASeasyUI -Config $Config -Advanced:$Advanced -Theme $Theme -Backend $Backend -ModulesRoot $script:PASModulesRoot
}

function ConvertTo-PASPlainDictionary {
    param($Value)
    if($null -eq $Value){return $null}
    if($Value -is [string] -or $Value -is [ValueType]){return $Value}
    if($Value -is [System.Collections.IDictionary]){$h=[ordered]@{};foreach($k in $Value.Keys){$h[[string]$k]=ConvertTo-PASPlainDictionary $Value[$k]};return $h}
    if($Value -is [pscustomobject]){$h=[ordered]@{};foreach($p in $Value.PSObject.Properties){$h[$p.Name]=ConvertTo-PASPlainDictionary $p.Value};return $h}
    if($Value -is [System.Collections.IEnumerable]){return ,@(foreach($i in $Value){ConvertTo-PASPlainDictionary $i})}
    return $Value
}

function Get-PASInstallRequirement {
    <# What a configuration needs before it can run: one credential per server and the Vault/AD secrets. #>
    param([Parameter(Mandatory)]$Configuration)
    $c=$Configuration
    $req=New-Object System.Collections.ArrayList
    $composed=($c -is [System.Collections.IDictionary] -and $c.Contains('execution'))
    $hostIds=@(@($c.components|Where-Object {$_}|ForEach-Object {[string]$_.host})+@($c.activeDirectory.join)|Where-Object {$_}|Select-Object -Unique)
    foreach($id in $hostIds){
        if(-not $c.hosts.Contains($id)){continue}
        $h=$c.hosts[$id]
        $ref=if($h.Contains('credentialRef') -and [string]$h.credentialRef){[string]$h.credentialRef}else{$id}
        if($h.os -eq 'Linux'){
            # Linux servers use SSH keys. A composed deployment (desktop / New-PASDeploymentConfiguration) authorises its
            # controller key with this password once, if key login does not work yet. Hand-written configs bring their own key.
            if(-not $composed){continue}
        }
        [void]$req.Add([pscustomobject]@{Kind='Credential';Key=$ref;HostId=$id;User=[string]$h.user;Os=[string]$h.os;
            Label=("$id ($([string]$h.address)) - $([string]$h.os) account")})
    }
    $types=@($c.components|Where-Object {$_}|ForEach-Object {[string]$_.type})
    foreach($psm in @($c.components|Where-Object {$_ -and $_.type -eq 'PSM'})){
        if($c.activeDirectory.mode -ne 'None' -and @($c.activeDirectory.join) -contains [string]$psm.host){
            [void]$req.Add([pscustomobject]@{Kind='Credential';Key='PSMDomainInstaller';HostId='';User=[string]$c.activeDirectory.joinUser;Os='Windows';Label='Domain account that installs PSM on a domain member'})
            break
        }
    }
    $secrets=@()
    if(@($types|Where-Object {$_ -ne 'AD'}).Count){$secrets+=@{Key='VaultAdmin';Label='Vault Administrator password'}}
    if($types -contains 'Vault'){$secrets+=@{Key='VaultMaster';Label='Vault Master password (new Vault)'}}
    if($types -contains 'DRVault'){$secrets+=@{Key='DRPassword';Label='DR user password (new DR)'}}
    if($types -contains 'AD'){$secrets+=@{Key='ADSafeMode';Label='AD Directory Services Restore Mode password'}}
    if(@($c.activeDirectory.join).Count){$secrets+=@{Key='DomainJoinPassword';Label=("Password of "+[string]$c.activeDirectory.joinUser+" (domain join)")}}
    foreach($s in $secrets){[void]$req.Add([pscustomobject]@{Kind='Secret';Key=$s.Key;HostId='';User='';Os='';Label=$s.Label})}
    return @($req)
}

function Resolve-PASInstallCredential {
    param($Configuration,[hashtable]$CredentialMap,[hashtable]$SecretMap,[securestring]$LabPassword)
    if($LabPassword -and $Configuration.security.profile -ne 'Lab'){throw '-LabPassword (one password for everything) requires a configuration with security.profile = Lab'}
    $creds=@{};foreach($k in $CredentialMap.Keys){$creds[$k]=$CredentialMap[$k]}
    $secrets=@{};foreach($k in $SecretMap.Keys){$secrets[$k]=$SecretMap[$k]}
    foreach($r in @(Get-PASInstallRequirement $Configuration)){
        if($r.Kind -eq 'Credential'){
            if($creds.ContainsKey($r.Key) -or ($r.HostId -and $creds.ContainsKey($r.HostId))){continue}
            if($LabPassword){$cred=[pscredential]::new($r.User,$LabPassword.Copy())}
            else{
                $cred=Get-Credential -UserName $r.User -Message ("PASeasyInstall: "+$r.Label)
                if(-not $cred){throw "Cancelled: no credential for $($r.Label)"}
            }
            $creds[$r.Key]=$cred
            if($r.HostId -and $r.HostId -ne $r.Key){$creds[$r.HostId]=$cred}
        }else{
            if($secrets.ContainsKey($r.Key)){continue}
            $secrets[$r.Key]=if($LabPassword){$LabPassword.Copy()}else{Read-Host -AsSecureString -Prompt ("PASeasyInstall: "+$r.Label)}
            if($secrets[$r.Key].Length -eq 0){throw "Empty secret: $($r.Label)"}
        }
    }
    # WinRM from a workgroup controller needs the target's own account: 'Administrator' -> '.\Administrator'.
    foreach($k in @($creds.Keys)){
        $hid=$null
        if($Configuration.hosts.Contains($k)){$hid=$k}
        if($hid -and $Configuration.hosts[$hid].os -eq 'Windows'){
            $u=[string]$creds[$k].UserName
            if($u -and $u -notmatch '[\\@]'){$creds[$k]=[pscredential]::new('.\'+$u,$creds[$k].Password)}
        }
    }
    return @{Credentials=$creds;Secrets=$secrets}
}

function Wait-PASeasyDeployment {
    param([Parameter(Mandatory)][string]$RunId,[int]$PollSeconds=15)
    $seen=@{};$terminal=@('Succeeded','Completed','Failed','LaunchFailed','Cancelled','Interrupted','Unknown','Blocked')
    while($true){
        $s=Get-PASEnvironmentSnapshot -RunId $RunId -Tail 5000
        foreach($e in @($s.Events)){
            $key=[string]$e.TimestampUtc+'|'+[string]$e.Component+'|'+[string]$e.Stage+'|'+[string]$e.Message
            if($seen.ContainsKey($key)){continue};$seen[$key]=$true
            $t=try{([datetime]$e.TimestampUtc).ToLocalTime().ToString('HH:mm:ss')}catch{''}
            Write-Host ('{0} {1,-10} {2,-22} {3,-8} {4}' -f $t,[string]$e.Component,[string]$e.Stage,[string]$e.Status,[string]$e.Message)
        }
        if([string]$s.Status -in $terminal){return $s}
        Start-Sleep -Seconds $PollSeconds
    }
}

function Invoke-PASeasyInstall {
    <#
    .SYNOPSIS
    Installs (or plans, or resumes) a lab from a saved deployment configuration, from the command line.
    .DESCRIPTION
    Use it with a project saved by the desktop or written with New-PASDeploymentConfiguration and
    Save-PASEnvironment. It validates the configuration and installer media, then asks for each server
    credential and Vault/AD secret, unless you pass -CredentialMap / -SecretMap, or -LabPassword for one
    lab password. It then starts the detached installer and returns the deployment id. The installation
    keeps running if you close the console; follow it with -Wait, Get-PASEnvironmentSnapshot or the desktop.
    Passwords stay in memory: they are never written to the project, logs or command lines.
    PASeasyInstall builds labs. Production use is at your own risk.
    .PARAMETER Config
    Deployment configuration (JSON).
    .PARAMETER PlanOnly
    Only validates the configuration and shows the plan. Contacts no server.
    .PARAMETER Resume
    Resumes a failed or interrupted engine run by its run id. For a desktop or composed deployment, pass the
    run id of the failed unit (shown in Get-PASEnvironmentSnapshot).
    .PARAMETER RetryFailedPreflight
    With -Resume: run a failed read-only preflight again (for example after installing a missing OS package).
    .PARAMETER CredentialMap
    @{ <server id> = PSCredential }. Servers that are missing are prompted for.
    .PARAMETER SecretMap
    @{ VaultAdmin / VaultMaster / DRPassword / ADSafeMode / DomainJoinPassword = SecureString }.
    .PARAMETER LabPassword
    One password for every server and secret. Lab profile only.
    .PARAMETER Wait
    Streams the progress events until the deployment ends, then returns the final snapshot.
    .EXAMPLE
    Invoke-PASeasyInstall -Config .\MyLab.json -PlanOnly
    .EXAMPLE
    $id = Invoke-PASeasyInstall -Config .\MyLab.json
    Get-PASEnvironmentSnapshot -RunId $id
    .EXAMPLE
    Invoke-PASeasyInstall -Config .\MyLab.json -LabPassword (Read-Host -AsSecureString 'Lab password') -Wait
    .EXAMPLE
    Invoke-PASeasyInstall -Resume 688d8e04f1874d41a75cda4441c00553 -RetryFailedPreflight
    #>
    [CmdletBinding(DefaultParameterSetName='Config',SupportsShouldProcess=$true)]
    param([Parameter(Mandatory,ParameterSetName='Config',Position=0)][string]$Config,
        [Parameter(ParameterSetName='Config')][switch]$PlanOnly,
        [Parameter(Mandatory,ParameterSetName='Resume')][ValidatePattern('^[a-f0-9]{32}$')][string]$Resume,
        [Parameter(ParameterSetName='Resume')][switch]$RetryFailedPreflight,
        [hashtable]$CredentialMap=@{},[hashtable]$SecretMap=@{},[securestring]$LabPassword,
        [switch]$Wait,[ValidateRange(5,600)][int]$PollSeconds=15)
    if($PSCmdlet.ParameterSetName -eq 'Resume'){
        $dataRoot=& (Get-Module PASeasyInstall.Core) {Get-PASDataRoot}
        $cfgPath=Join-Path (Join-Path (Join-Path $dataRoot 'Runs') $Resume) 'config.json'
        if(-not(Test-Path -LiteralPath $cfgPath -PathType Leaf)){
            if(Test-Path -LiteralPath (Join-Path (Join-Path (Join-Path $dataRoot 'fleets') $Resume) 'fleet.json')){
                throw "$Resume is a composed deployment. Resume the failed unit instead: its run id is in (Get-PASEnvironmentSnapshot -RunId $Resume)."
            }
            throw "Run $Resume not found under $dataRoot"
        }
        $c=ConvertTo-PASPlainDictionary ([IO.File]::ReadAllText($cfgPath)|ConvertFrom-Json)
        $auth=Resolve-PASInstallCredential $c $CredentialMap $SecretMap $LabPassword
        if(-not $PSCmdlet.ShouldProcess($Resume,'Resume deployment')){return}
        [void](Resume-PASeasyDeployment -RunId $Resume -CredentialMap $auth.Credentials -SecretMap $auth.Secrets -RetryFailedPreflight:$RetryFailedPreflight -Confirm:$false)
        $auth=$null
        if($Wait){return (Wait-PASeasyDeployment -RunId $Resume -PollSeconds $PollSeconds)}
        return $Resume
    }
    $path=(Resolve-Path -LiteralPath $Config).ProviderPath
    $valid=Test-PASEnvironment -Config $path -CheckMedia:(-not $PlanOnly)
    foreach($w in @($valid.Warnings)){Write-Warning $w}
    if(-not $valid.Valid){throw ('Configuration is not ready: '+(@($valid.Issues) -join '; '))}
    if($PlanOnly){return (Get-PASEnvironmentPlan -Configuration $valid.Configuration)}
    $c=$valid.Configuration
    $auth=Resolve-PASInstallCredential $c $CredentialMap $SecretMap $LabPassword
    if(-not $PSCmdlet.ShouldProcess([string]$c.name,'Install the lab described by '+$path)){return}
    $id=Start-PASEnvironment -Configuration $c -CredentialMap $auth.Credentials -SecretMap $auth.Secrets -Confirm:$false
    $auth=$null
    if($Wait){return (Wait-PASeasyDeployment -RunId $id -PollSeconds $PollSeconds)}
    return $id
}

Export-ModuleMember -Function @(
    'Start-PASeasyInstall','Invoke-PASeasyInstall',
    'New-PASDeploymentConfiguration','Get-PASMediaInventory','Get-PASMediaSelection',
    'Test-PASEnvironment','Get-PASEnvironmentPlan','Save-PASEnvironment','Start-PASEnvironment',
    'Get-PASEnvironmentSnapshot','Get-PASEnvironmentEvents','Get-PASStageCatalog',
    'Resume-PASeasyDeployment','Test-PASEnvironmentHealth','Export-PASRunData')
