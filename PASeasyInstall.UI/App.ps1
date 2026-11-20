# PASeasyInstall desktop UI (NativeHTMLKit.UI public API + documented SDK calls for drop and dialogs).
# This file runs twice: once as launcher and once as the supervised backend. Nothing with side
# effects may run above Start-NativeHTMLKitScript.
#
# The UI talks to the installer ONLY through the commands in Backend/Backend.Contract.ps1.
#   -Backend Live  (default) the PASeasyInstall module
#   -Backend Mock  the same module with a simulated installation run; no servers touched
[CmdletBinding()]
param(
    [string]$Config = '',
    [ValidateSet('Live', 'Mock')][string]$Backend = 'Live',
    [string]$StartDirectory = ''
)
$ErrorActionPreference='Stop'
Import-Module NativeHTMLKit.UI -ErrorAction Stop
if(-not $StartDirectory){$StartDirectory=(Get-Location).ProviderPath}
$launchArgs=@('-Backend',$Backend,'-StartDirectory',$StartDirectory)
if($Config){$launchArgs+=@('-Config',$Config)}
$pasApp=Start-NativeHTMLKitScript -Name 'PASeasyInstall' -ScriptPath $PSCommandPath -ArgumentList $launchArgs
# ---- side effects allowed below this line ----

. (Join-Path $PSScriptRoot 'Backend/Backend.Contract.ps1')
. (Join-Path $PSScriptRoot 'Presentation.ps1')
$backendKind=Import-PASUIBackend -Kind $Backend
$css=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Theme.css'))
$script:LabPassword=[string]$env:PASEASY_LAB_PASSWORD   # Lab-mode prefill only when the operator sets it; no password ships in the code
$script:PASComponents=@('PVWA','CPM','PSM','PSMP')
$script:PASMaxInstances=@{PVWA=4;CPM=4;PSM=4;PSMP=4}   # UI slots per component
$script:PASComponentInfo=@{
    PVWA='Web access portal (Windows)'; CPM='Password rotation (Windows)'; PSM='Session isolation and recording (Windows)'
    PSMP='SSH session proxy (Linux)'}
$script:PASMediaKinds=@($script:PASUIMediaOrder|ForEach-Object {$_.C})

$script:PASSteps=@(
    @{N=1;Title='Project & media';Hint='Name the environment and add the installer media'},
    @{N=2;Title='What to install';Hint='Choose the Vault option and how many of each component'},
    @{N=3;Title='Servers';Hint='Name each server and enter its address'},
    @{N=4;Title='Credentials';Hint='Accounts and passwords for the servers and the Vault'},
    @{N=5;Title='Review plan';Hint='Check everything before running'},
    @{N=6;Title='Install';Hint='Run the installation and follow progress'}
)

function Get-PASUILocalAddress {
    <# Best guess at this computer's LAN IPv4: an up, non-loopback interface with a default gateway. #>
    try{
        $nics=[Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()|Where-Object {
            $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback'}
        $withGw=@($nics|Where-Object {@($_.GetIPProperties().GatewayAddresses|Where-Object {$_.Address.AddressFamily -eq 'InterNetwork'}).Count})
        foreach($nic in @($withGw)+@($nics)){
            foreach($ua in $nic.GetIPProperties().UnicastAddresses){
                if($ua.Address.AddressFamily -eq 'InterNetwork' -and -not [Net.IPAddress]::IsLoopback($ua.Address)){return $ua.Address.ToString()}
            }
        }
    }catch{}
    return ''
}

# ---------------------------------------------------------------- state
$state=@{
    Step=(New-NHKUiState -Value 1)
    Name=(New-NHKUiState -Value 'MyPAM'); ProjectDir=(New-NHKUiState -Value $StartDirectory)
    VaultMode=(New-NHKUiState -Value 'Primary')                      # Primary | PrimaryDR | Existing
    Controller=(New-NHKUiState -Value (Get-PASUILocalAddress)); User=(New-NHKUiState -Value 'Administrator'); LinuxUser=(New-NHKUiState -Value 'root')
    Primary=(New-NHKUiState -Value ''); DR=(New-NHKUiState -Value ''); ExistingVault=(New-NHKUiState -Value '')
    LabMode=(New-NHKUiState -Value $true); Universal=(New-NHKUiState -Value $script:LabPassword)
    PerServerUser=(New-NHKUiState -Value $false); UserPrimary=(New-NHKUiState -Value ''); UserDR=(New-NHKUiState -Value '')
    PwPrimary=(New-NHKUiState -Value ''); PwDR=(New-NHKUiState -Value '')
    PwVaultAdmin=(New-NHKUiState -Value ''); PwMaster=(New-NHKUiState -Value ''); PwDRUser=(New-NHKUiState -Value '')
    AcceptEula=(New-NHKUiState -Value $false)
    Busy=(New-NHKUiState -Value $false)
    Ready=(New-NHKUiState -Value $false)                              # plan reviewed without issues and every password entered
}
foreach($c in $script:PASComponents){
    $state['Count'+$c]=New-NHKUiState -Value '0'
    for($i=1;$i -le $script:PASMaxInstances[$c];$i++){
        $state["Name$c$i"]=New-NHKUiState -Value ('{0}{1:00}' -f $c,$i)
        $state["Addr$c$i"]=New-NHKUiState -Value ''
        $state["Pw$c$i"]=New-NHKUiState -Value ''
        $state["User$c$i"]=New-NHKUiState -Value ''
    }
}
foreach($k in $script:PASMediaKinds){
    $state['Choice'+$k]=New-NHKUiState -Value '0'
    $state['Found'+$k]=New-NHKUiState -Value $false
}
$script:pasComputed=New-Object System.Collections.ArrayList
function New-PASUIComputed {param([object[]]$DependsOn,$Data,[scriptblock]$Compute)
    $c=New-NHKUiComputed -DependsOn $DependsOn -Data $Data -Compute $Compute
    [void]$script:pasComputed.Add($c); return $c
}
function New-PASUIEquals {param($Source,$Value,[switch]$Not)
    return (New-PASUIComputed -DependsOn @($Source) -Data @{S=$Source;V=$Value;Not=[bool]$Not} -Compute {
        param($d) $eq=([string]$d.S.Value -eq [string]$d.V); if($d.Not){return (-not $eq)}; return $eq })
}
function New-PASUIAtLeast {param($Source,[int]$N)
    return (New-PASUIComputed -DependsOn @($Source) -Data @{S=$Source;N=$N} -Compute {param($d) return ([int]$d.S.Value -ge $d.N)})
}
$state.IsExisting=New-PASUIEquals $state.VaultMode 'Existing'
$state.InstallsVault=New-PASUIEquals $state.VaultMode 'Existing' -Not
$state.ShowDR=New-PASUIEquals $state.VaultMode 'PrimaryDR'
$state.NotLab=New-PASUIEquals $state.LabMode $true -Not
$state.ShowPerServer=New-PASUIComputed -DependsOn @($state.LabMode,$state.PerServerUser) -Data $state -Compute {
    param($s) return ([bool]$s.PerServerUser.Value -or -not [bool]$s.LabMode.Value) }
foreach($c in $script:PASComponents){
    $state['Any'+$c]=New-PASUIAtLeast $state['Count'+$c] 1
    for($i=1;$i -le $script:PASMaxInstances[$c];$i++){$state["Show$c$i"]=New-PASUIAtLeast $state['Count'+$c] $i}
}
$countStates=@($script:PASComponents|ForEach-Object {$state['Count'+$_]})
$state.AnyLinux=New-PASUIComputed -DependsOn @($state.CountPSMP) -Data $state -Compute {
    param($s) return ([int]$s.CountPSMP.Value -gt 0) }
$state.AnyComponent=New-PASUIComputed -DependsOn $countStates -Data $state -Compute {
    param($s) return [bool](@($script:PASComponents|Where-Object {[int]$s['Count'+$_].Value -gt 0}).Count) }
$state.ProjectPath=New-PASUIComputed -DependsOn @($state.Name,$state.ProjectDir) -Data $state -Compute {
    param($s) $safe=([string]$s.Name.Value -replace '[^A-Za-z0-9_.-]','_'); if(-not $safe){$safe='project'}
    return (Join-Path ([string]$s.ProjectDir.Value) ('PASeasyInstall-'+$safe+'.json')) }
$state.ScopeSummary=New-PASUIComputed -DependsOn (@($state.VaultMode)+$countStates) -Data $state -Compute {
    param($s)
    $comps=@($script:PASComponents|Where-Object {[int]$s['Count'+$_].Value -gt 0}|ForEach-Object {
        $n=[int]$s['Count'+$_].Value; if($n -gt 1){"$n× $_"}else{$_}})
    $vault=switch([string]$s.VaultMode.Value){'Primary'{'a new Primary Vault'}'PrimaryDR'{'a new Primary Vault and DR Vault'}default{''}}
    if($vault -and $comps.Count){return ('Installs '+$vault+', then '+($comps -join ', ')+', one after another.')}
    if($vault){return ('Installs '+$vault+' only. Components are skipped; you can add them later.')}
    if($comps.Count){return ('Installs '+($comps -join ', ')+' and registers them to your existing Vault.')}
    return 'Nothing selected yet. Choose at least one component, or install a Vault.' }
# Install is offered only when nothing is running and the review found nothing left to fix.
$state.InstallBlocked=New-PASUIComputed -DependsOn @($state.Busy,$state.Ready) -Data $state -Compute {
    param($s) return ([bool]$s.Busy.Value -or -not [bool]$s.Ready.Value) }
$state.FirstStep=New-PASUIEquals $state.Step 1
$state.NotLastStep=New-PASUIEquals $state.Step 6 -Not
$state.NextLabel=New-PASUIComputed -DependsOn @($state.Step) -Data $state -Compute {
    param($s) if([int]$s.Step.Value -eq 5){return 'Continue to install  →'}; return 'Next  →' }
$state.StepTitle=New-PASUIComputed -DependsOn @($state.Step) -Data $state -Compute {
    param($s) $x=$script:PASSteps[[int]$s.Step.Value-1]; return ('Step '+$x.N+' of 6 · '+$x.Title) }

# Working data that never reaches markup.
$work=@{MediaSources=@();Inventory=@();Candidates=@{};Recommended=@{};Selection=@{};ScopeAuto=$true;Applying=$false
    Configuration=$null;Validation=$null;Plan=$null;Requirements=@();PreviewHash='';SavedFile='';CredIssues=@()
    RunId='';LastRefresh=[datetime]::MinValue;Catalog=@{};StageCounts=@{};EventHistory=$null;EventHistoryRun=''}
foreach($k in @('Vault','DR','PVWA','CPM','PSM','PSMP','AD')){
    $work.Catalog[$k]=@(Get-PASStageCatalog -Component $k | Sort-Object -Property Order | ForEach-Object {[string]$_.Stage})
    $work.StageCounts[$k]=$work.Catalog[$k].Count
}
# Once the user picks the scope themselves, new media no longer changes it.
$scopeTouched={param($v,$ctx) if(-not $work.Applying){$work.ScopeAuto=$false}}
foreach($st in @($state.VaultMode)+$countStates){$null=$st.Subscribe($scopeTouched,$null)}
# A different installer picked in a dropdown replaces the automatic choice for that component.
$choiceChanged={param($v,$kind) if(-not $work.Applying){Update-PASUISelection $kind}}
foreach($k in $script:PASMediaKinds){$null=$state['Choice'+$k].Subscribe($choiceChanged,$k)}
$script:pasChoiceNodes=@{}
$perServerOn={param($v,$ctx) if(-not $v){return}
    foreach($k in @('UserPrimary','UserDR')){if(-not [string]$state[$k].Value){$state[$k].Set([string]$state.User.Value)}}
    foreach($c in $script:PASComponents){for($i=1;$i -le $script:PASMaxInstances[$c];$i++){if(-not [string]$state["User$c$i"].Value){$state["User$c$i"].Set((Get-PASUIDefaultUser $c))}}}}
$null=$state.PerServerUser.Subscribe($perServerOn,$null)
$script:pasAlive=$true

# ---------------------------------------------------------------- helpers
function Add-PASUIClass {param($Node,[string]$Class) $Node.Attrs['class']=(([string]$Node.Attrs['class'])+' '+$Class).Trim(); return $Node}
function Set-PASUIHtml {param($Node,[string]$Html)
    if($null -eq $ui.Document){$Node.Raw=$Html;return}
    Set-NativeHTMLKitDocumentHtml -Document $ui.Document -Element $Node.Id -Html $Html
}
function Write-PASUIMessage {param([ValidateSet('info','ok','warn','error')][string]$Kind,[string]$Text)
    Set-PASUIHtml $script:pasMessage (ConvertTo-PASUIMessageHtml -Kind $Kind -Text $Text)
}
function Get-PASUIDefaultUser {param([string]$Type) if($Type -eq 'PSMP'){return [string]$state.LinuxUser.Value}; return [string]$state.User.Value}
function Get-PASUIUser {param([string]$Key,[string]$Type)
    # Per-server account if switched on and filled in, otherwise the default for the server's OS.
    if($state.PerServerUser.Value -and ([string]$state[$Key].Value).Trim()){return ([string]$state[$Key].Value).Trim()}
    return (Get-PASUIDefaultUser $Type)
}
function Get-PASUIInstances {
    <# Selected component instances in UI order: @(@{Type;Index;Name;Address}) #>
    foreach($c in $script:PASComponents){
        for($i=1;$i -le [int]$state['Count'+$c].Value;$i++){
            @{Type=$c;Index=$i;Name=([string]$state["Name$c$i"].Value).Trim();Address=([string]$state["Addr$c$i"].Value).Trim();Username=(Get-PASUIUser "User$c$i" $c)}
        }
    }
}
function Get-PASUIInputHash {
    $keys=@('Name','ProjectDir','VaultMode','Controller','User','LinuxUser','Primary','DR','ExistingVault','PerServerUser','UserPrimary','UserDR','LabMode','AcceptEula')
    foreach($c in $script:PASComponents){$keys+='Count'+$c; for($i=1;$i -le $script:PASMaxInstances[$c];$i++){$keys+=@("Name$c$i","Addr$c$i","User$c$i")}}
    foreach($k in $script:PASMediaKinds){$keys+='Choice'+$k}
    $content=(($keys|ForEach-Object {[string]$state[$_].Value}) + @($work.MediaSources)) -join "`n"
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($content)))).Replace('-','')}finally{$sha.Dispose()}
}

# ---- media
function Update-PASUIMediaView {
    Set-PASUIHtml $script:pasMedia (ConvertTo-PASUIMediaHtml -Inventory $work.Inventory -Selection $work.Selection -Sources $work.MediaSources)
    Set-PASUIHtml $script:pasCompMedia (ConvertTo-PASUIComponentMediaHtml -Selection $work.Selection)
}
function Update-PASUISelection {param([string]$Kind)
    $list=@($work.Candidates[$Kind]); $i=[int]$state['Choice'+$Kind].Value
    if($list.Count -and $i -ge 0 -and $i -lt $list.Count){$work.Selection[$Kind]=$list[$i]}else{$work.Selection.Remove($Kind)}
    Update-PASUIMediaView
}
function Update-PASUICandidates {
    <# One dropdown per detected kind; the recommended installer first and preselected. #>
    $work.Candidates=@{}; $work.Recommended=Get-PASMediaSelection -Inventory $work.Inventory
    $work.Applying=$true
    try{
        foreach($k in $script:PASMediaKinds){
            $rec=$work.Recommended[$k]
            $others=@($work.Inventory|Where-Object {$_.Component -eq $k -and -not [object]::ReferenceEquals($_,$rec)}|
                Sort-Object -Descending -Property @{Expression={try{[version]$_.Version}catch{[version]'0.0'}}},Variant)
            $list=@(); if($rec){$list=@($rec)+$others}
            $work.Candidates[$k]=$list
            $state['Choice'+$k].Set('0')
            $state['Found'+$k].Set($list.Count -gt 1)   # a dropdown only where there is a real choice
            if($list.Count -and $script:pasChoiceNodes.ContainsKey($k) -and $ui.Document){
                Set-NativeHTMLKitDocumentHtml -Document $ui.Document -Element $script:pasChoiceNodes[$k].Id -Html (ConvertTo-PASUIOptionsHtml -Candidates $list -Selected 0 -Recommended 0)
                Set-NativeHTMLKitDocumentValue -Document $ui.Document -Element $script:pasChoiceNodes[$k].Id -Value '0'
            }
        }
    }finally{$work.Applying=$false}
    $work.Selection=@{}; foreach($k in $script:PASMediaKinds){if(@($work.Candidates[$k]).Count){$work.Selection[$k]=$work.Candidates[$k][0]}}
}
function Add-PASUIMedia {param([string[]]$Paths)
    $new=@($Paths|Where-Object {$_ -and ($work.MediaSources -notcontains $_)})
    if(-not $new.Count){return}
    $work.MediaSources=@($work.MediaSources)+$new
    $work.Inventory=@(Get-PASMediaInventory -Path $work.MediaSources)
    Update-PASUICandidates
    if($work.ScopeAuto){
        # Preselect what the media supports (one instance each); the user can change it on step 2.
        $work.Applying=$true
        try{
            $mode=if($work.Selection['Vault'] -and $work.Selection['DR']){'PrimaryDR'}elseif($work.Selection['Vault']){'Primary'}else{'Existing'}
            $state.VaultMode.Set($mode)
            foreach($c in $script:PASComponents){$state['Count'+$c].Set($(if($work.Selection[$c]){'1'}else{'0'}))}
        }finally{$work.Applying=$false}
    }
    Update-PASUIMediaView
    $found=@($script:PASUIMediaOrder|Where-Object {$work.Selection[$_.C]}|ForEach-Object {$_.L})
    $multi=@($script:PASUIMediaOrder|Where-Object {@($work.Candidates[$_.C]).Count -gt 1}|ForEach-Object {$_.L})
    if($found.Count){
        $t='Detected: '+($found -join ', ')+'.'
        if($multi.Count){$t+=' Several files found for '+($multi -join ', ')+': the recommended one is used; pick another below only if you need it.'}
        Write-PASUIMessage ok $t
    } else {Write-PASUIMessage warn 'No CyberArk installers recognised in what you added.'}
}
function Clear-PASUIMedia {
    $work.MediaSources=@();$work.Inventory=@();$work.ScopeAuto=$true
    Update-PASUICandidates; Update-PASUIMediaView; Write-PASUIMessage info 'Media list cleared.'
}

# ---- plan
function Get-PASUIProposedConfiguration {
    $inst=@(Get-PASUIInstances|ForEach-Object {@{Type=$_.Type;Name=$_.Name;Address=$_.Address;Username=$_.Username}})
    return New-PASLabConfiguration -Environment ([string]$state.Name.Value) -VaultMode ([string]$state.VaultMode.Value) `
        -Instances $inst -ControllerAddress ([string]$state.Controller.Value) `
        -PrimaryAddress ([string]$state.Primary.Value) -DRAddress ([string]$state.DR.Value) `
        -ExistingVaultAddress ([string]$state.ExistingVault.Value) `
        -Username ([string]$state.User.Value) -LinuxUsername ([string]$state.LinuxUser.Value) -Media $work.Selection `
        -PrimaryUsername (Get-PASUIUser 'UserPrimary' 'Vault') -DRUsername (Get-PASUIUser 'UserDR' 'Vault') `
        -SecurityProfile $(if($state.LabMode.Value){'Lab'}else{'Secure'}) -AcceptEula:([bool]$state.AcceptEula.Value)
}
function Reset-PASUIReview {
    $work.Configuration=$null;$work.Validation=$null;$work.Plan=$null;$work.Requirements=@();$work.PreviewHash='';$work.SavedFile=''
}
function Invoke-PASUIReview {
    <# Validates the proposed configuration and asks the backend for its plan and for the credentials it
       needs. The result is kept until an input changes. Returns $true when there is a plan. #>
    $hash=Get-PASUIInputHash
    $err=''
    if(-not ($work.PreviewHash -eq $hash -and $work.Plan)){
        Reset-PASUIReview
        try{
            $work.Validation=Test-PASLabConfiguration -Configuration (Get-PASUIProposedConfiguration)
            if($work.Validation.Valid){
                $cfg=$work.Validation.Configuration
                $plan=Get-PASLabPlan -Configuration $cfg
                $work.Requirements=@(Get-PASCredentialRequirement -Configuration $cfg)
                $work.Configuration=$cfg
                $work.Plan=$plan
                $work.PreviewHash=$hash
            }
        }catch{$err=$_.Exception.Message}
    }
    $work.CredIssues=@(Get-PASUICredentialIssues)
    Update-PASUIReviewView -ErrorText $err
    return [bool]$work.Plan
}
function Get-PASUICredentialMode {
    if($state.LabMode.Value){return 'Lab mode: one universal password is used for every server and Vault account. Not for production.'}
    return 'Individual passwords per server and Vault account.'
}
function Update-PASUIReviewView {param([string]$ErrorText='')
    Set-PASUIHtml $script:pasReview (ConvertTo-PASUIReviewHtml -Validation $work.Validation -Plan $work.Plan -StageCounts $work.StageCounts `
        -ErrorText $ErrorText -ExtraIssues $work.CredIssues -CredentialMode (Get-PASUICredentialMode))
    Update-PASUIReadiness
}

# ---- credentials (held only in process memory; never saved to the project)
# WHAT is needed comes from the backend: Get-PASCredentialRequirement lists every server credential and
# every secret of the reviewed configuration, with the key it must be handed over under. The page has a
# fixed set of password inputs, so each requirement is matched to the input that belongs to it.
$script:PASUISecretFields=@{VaultAdmin='PwVaultAdmin';VaultMaster='PwMaster';DRPassword='PwDRUser'}
function Get-PASUIServerField {
    <# State key of the password input of one server, found through the plan items installed on it.
       Instances that share a server use the input of the first of them. '' when the page has none. #>
    param([string]$HostId)
    $onHost=@($work.Plan.Items|Where-Object {[string]$_.Host -eq $HostId})
    if(@($onHost|Where-Object {$_.Type -eq 'Vault'}).Count){return 'PwPrimary'}
    if(@($onHost|Where-Object {$_.Type -eq 'DRVault'}).Count){return 'PwDR'}
    $names=@($onHost|ForEach-Object {[string]$_.Name})
    foreach($inst in Get-PASUIInstances){
        if($names -contains $inst.Name){return ('Pw'+$inst.Type+$inst.Index)}
    }
    return ''
}
function Get-PASUIPasswordSlots {
    <# One slot per requirement: @{Kind;Key;User;Label;Field}. Field is the state key of its password input. #>
    $slots=@()
    foreach($requirement in @($work.Requirements)){
        if($requirement.Kind -eq 'Secret'){
            $field=[string]$script:PASUISecretFields[[string]$requirement.Key]
        }else{
            $field=Get-PASUIServerField ([string]$requirement.HostId)
        }
        $slots+=@{Kind=[string]$requirement.Kind;Key=[string]$requirement.Key;User=[string]$requirement.User
            Label=[string]$requirement.Label;Field=$field}
    }
    return $slots
}
function Get-PASUICredentialIssues {
    # One lab password fills every slot.
    if($state.LabMode.Value){
        if(-not [string]$state.Universal.Value){return @('Enter the universal lab password')}
        return @()
    }
    $issues=@()
    foreach($slot in Get-PASUIPasswordSlots){
        if(-not $slot.Field){
            $issues+=('Password missing: '+$slot.Label+' (this page has no field for it; use lab mode, or Install-PASLab at the prompt)')
        }elseif(-not [string]$state[$slot.Field].Value){
            $issues+=('Password missing: '+$slot.Label)
        }
    }
    return $issues
}
function New-PASUISecure {param([string]$Text)
    $s=New-Object Security.SecureString; foreach($ch in $Text.ToCharArray()){$s.AppendChar($ch)}; $s.MakeReadOnly(); return $s
}
function Get-PASUICredentialMaps {
    <# The -CredentialMap and -SecretMap of Install-PASLab, keyed as the requirements say. #>
    $issues=@(Get-PASUICredentialIssues); if($issues.Count){throw ($issues -join '; ')}
    $creds=@{}; $secrets=@{}
    foreach($slot in Get-PASUIPasswordSlots){
        if($state.LabMode.Value){$pw=[string]$state.Universal.Value}else{$pw=[string]$state[$slot.Field].Value}
        if($slot.Kind -eq 'Secret'){
            $secrets[$slot.Key]=New-PASUISecure $pw
        }else{
            $creds[$slot.Key]=[pscredential]::new($slot.User,(New-PASUISecure $pw))
        }
    }
    return @{Credentials=$creds;Secrets=$secrets}
}
function Clear-PASUIPasswords {
    # Every password the window holds, the lab password included.
    $keys=@('Universal','PwPrimary','PwDR','PwVaultAdmin','PwMaster','PwDRUser')
    foreach($c in $script:PASComponents){for($i=1;$i -le $script:PASMaxInstances[$c];$i++){$keys+="Pw$c$i"}}
    foreach($k in $keys){$state[$k].Set('')}
}

# ---- install
function Update-PASUIReadiness {
    $planOk=[bool]$work.Plan -and $work.PreviewHash -eq (Get-PASUIInputHash)
    $credOk=-not @(Get-PASUICredentialIssues).Count
    $credDetail=if($work.RunId){'Handed to the controller'}elseif(-not $credOk){'Missing: '+((@(Get-PASUICredentialIssues)|ForEach-Object {$_ -replace '^(Enter the|Password missing:) ',''}) -join ', ')}elseif($state.LabMode.Value){'Lab mode: universal password'}else{'All passwords entered'}
    $saved=[string]$state.ProjectPath.Value
    $rows=@(
        @{Label='Plan reviewed';Done=$planOk;Detail=$(if($planOk){$n=@($work.Plan.Items).Count;'{0} component{1} ready' -f $n,$(if($n -eq 1){''}else{'s'})}else{'Open Review plan and resolve any issues'})},
        @{Label='Project file';Done=[bool]$work.SavedFile;Detail=$(if($work.SavedFile){$work.SavedFile}else{$saved+' (saved on Install)'})},
        @{Label='Credentials';Done=($credOk -or [bool]$work.RunId);Detail=$credDetail},
        @{Label='Installation';Done=[bool]$work.RunId;Detail=$(if($work.RunId){'Run '+$work.RunId+' launched'}else{'Not started'})}
    )
    Set-PASUIHtml $script:pasReadiness (ConvertTo-PASUIReadinessHtml -Rows $rows)
    $ready=[bool]($planOk -and $credOk)
    if([bool]$state.Ready.Value -ne $ready){$state.Ready.Set($ready)}
}
function Save-PASUIProject {
    if(-not (Invoke-PASUIReview)){throw 'The plan has problems; open Review plan to see them.'}
    # The project path is shown on step 1; replacing a project with the same name is intentional.
    $path=[string]$state.ProjectPath.Value
    $null=Export-PASLabConfiguration -Configuration $work.Configuration -Path $path -Force
    $work.SavedFile=$path
    Update-PASUIReadiness
}
function Start-PASUIInstall {
    if($state.Busy.Value){throw 'An installation is already running.'}
    if(-not (Invoke-PASUIReview)){throw 'The plan has problems; open Review plan to see them.'}
    $maps=Get-PASUICredentialMaps
    $media=Test-PASLabConfiguration -Configuration $work.Configuration -CheckMedia
    if(-not $media.Valid){throw ('Media check failed: '+($media.Issues -join '; '))}
    Save-PASUIProject
    $id=Install-PASLab -Configuration $work.Configuration -CredentialMap $maps.Credentials -SecretMap $maps.Secrets -Confirm:$false
    # The controller has the passwords now; the window keeps none of them.
    $maps=$null
    $work.RunId=[string]$id; $work.LastRefresh=[datetime]::MinValue
    Clear-PASUIPasswords
    $state.Busy.Set($true)
    Update-PASUIReadiness; Update-PASUIDashboard
    Write-PASUIMessage info 'Installation started. The controller runs independently of this window; progress below comes from its event log.'
}
function Update-PASUIDashboard {
    if(-not $work.RunId){return}
    # First refresh of a run reads its whole history; later refreshes read only the newest events and merge them,
    # so completed stages stay completed however long the run gets.
    if(-not $work.EventHistory -or $work.EventHistoryRun -ne $work.RunId){$work.EventHistory=@{};$work.EventHistoryRun=$work.RunId;$tail=5000}else{$tail=300}
    $snap=Get-PASRun -RunId $work.RunId -Tail $tail
    $all=@(Merge-PASUIEventHistory -History $work.EventHistory -Events @($snap.Events))
    $view=[pscustomobject]@{
        RunId=[string]$snap.RunId; Status=[string]$snap.Status; Message=[string]$snap.Message
        CurrentComponent=[string]$snap.CurrentComponent; LastStep=[string]$snap.LastStep
        ErrorEvents=@($all|Where-Object {$_.Status -eq 'Failed'}).Count
        RunDirectory=[string]$snap.RunDirectory; Components=@($snap.Components); Events=$all
    }
    Set-PASUIHtml $script:pasTimeline (ConvertTo-PASUIDashboardHtml -Snapshot $view -PlanItems @($work.Plan.Items) -Catalog $work.Catalog)
    if(-not (Test-PASUIRunActive $view.Status) -and $state.Busy.Value){
        $state.Busy.Set($false)
        if($view.Status -eq 'Succeeded'){
            Write-PASUIMessage ok 'Installer workflow completed. Run the component health checks before production use.'
        }else{
            Write-PASUIMessage error ('Installation stopped: '+$view.Status+'. The run id and the commands to resume it or to export its logs are shown under Progress.')
        }
    }
}

# ---- saved project
function Import-PASUIProject {
    <# Fills the wizard from a saved project file (-Config): name, Vault option, addresses, component
       servers and default accounts. Media and passwords are not in a project file and are entered again;
       per-server accounts and the PSMP licence acceptance are not taken over either. #>
    param([string]$Path)
    $cfg=Import-PASLabConfiguration -Path $Path
    $plan=Get-PASLabPlan -Configuration $cfg
    $items=@($plan.Items)
    $work.Applying=$true
    try{
        if([string]$cfg.name){$state.Name.Set([string]$cfg.name)}
        $state.ProjectDir.Set((Split-Path -Parent $Path))
        if([string]$cfg.controllerAddress){$state.Controller.Set([string]$cfg.controllerAddress)}
        if($cfg.security){$state.LabMode.Set(([string]$cfg.security.profile -eq 'Lab'))}
        $vault=@($items|Where-Object {$_.Type -eq 'Vault'})
        $dr=@($items|Where-Object {$_.Type -eq 'DRVault'})
        if($vault.Count){
            $state.VaultMode.Set($(if($dr.Count){'PrimaryDR'}else{'Primary'}))
            $state.Primary.Set([string]$vault[0].Address)
            if($dr.Count){$state.DR.Set([string]$dr[0].Address)}
        }else{
            $state.VaultMode.Set('Existing')
            $state.ExistingVault.Set([string]$plan.ExistingVault)
        }
        foreach($c in $script:PASComponents){
            $list=@($items|Where-Object {$_.Type -eq $c})
            $n=[Math]::Min($list.Count,[int]$script:PASMaxInstances[$c])
            for($i=1;$i -le $n;$i++){
                $state["Name$c$i"].Set([string]$list[$i-1].Name)
                $state["Addr$c$i"].Set([string]$list[$i-1].Address)
            }
            $state['Count'+$c].Set([string]$n)
        }
        # Default accounts: the first Windows and the first Linux account the configuration asks for.
        $windowsUser='';$linuxUser=''
        foreach($requirement in @(Get-PASCredentialRequirement -Configuration $cfg|Where-Object {$_.Kind -eq 'Credential' -and $_.HostId})){
            if($requirement.Os -eq 'Linux'){if(-not $linuxUser){$linuxUser=[string]$requirement.User}}
            elseif(-not $windowsUser){$windowsUser=[string]$requirement.User}
        }
        if($windowsUser){$state.User.Set($windowsUser)}
        if($linuxUser){$state.LinuxUser.Set($linuxUser)}
    }finally{$work.Applying=$false}
    $work.ScopeAuto=$false   # media added later must not change what the project selects
    Reset-PASUIReview
    Write-PASUIMessage ok ('Opened '+[IO.Path]::GetFileName($Path)+'. Add the installer media and enter the passwords; they are never stored in a project file.')
}

# ---- navigation and dialogs
function Set-PASUIStep {param([int]$N)
    if($N -lt 1 -or $N -gt 6){return}
    $state.Step.Set($N)
    if($N -ge 5){
        $ok=Invoke-PASUIReview
        if($N -eq 5){
            if($ok -and -not $work.CredIssues.Count){Write-PASUIMessage ok 'Plan is ready. Nothing has been sent to any server yet.'}
            else{Write-PASUIMessage warn 'Some things still need attention. Fix the listed items, then come back here.'}
        }
    } else {Write-PASUIMessage info ($script:PASSteps[$N-1].Hint+'. No server is contacted until you click Install.')}
}
function Show-PASUIDialog {param([string]$Kind,[string]$Title,[switch]$Multiple)
    $p=@{Window=$ui.Window;Kind=$Kind;Title=$Title}; if($Multiple){$p.Multiple=$true}
    try{$pick=Show-NativeHTMLKitFileDialog @p}catch{Write-PASUIMessage warn ('File dialog unavailable: '+$_.Exception.Message);return @()}
    if($pick.cancelled){return @()}; return @($pick.paths)
}
function Invoke-PASUISafe {param([scriptblock]$Action) try{& $Action}catch{Write-PASUIMessage error $_.Exception.Message}}

# Small builders keep the layout below readable.
function Add-PASUIChoice {param([string]$Value,[string]$Title,[string]$Text,$Bind=$state.VaultMode)
    $on=New-PASUIEquals $Bind $Value; $off=New-PASUIEquals $Bind $Value -Not
    $card=Add-NHKUiColumn -UI $ui -Content {
        $null=Add-NHKUiHtml -UI $ui -Markup ('<div class="pas-choice-t">'+(Get-PASUIEscaped $Title)+'</div><div class="pas-choice-d">'+(Get-PASUIEscaped $Text)+'</div>')
        $null=Add-NHKUiWhen -UI $ui -Bind $on -Content { $null=Add-PASUIClass (Add-NHKUiButton -UI $ui -Text '✓  Selected' -Variant primary) 'pas-choice-btn' }
        $null=Add-NHKUiWhen -UI $ui -Bind $off -Content {
            $null=Add-PASUIClass (Add-NHKUiButton -UI $ui -Text 'Select' -Variant secondary -Data @{S=$Bind;V=$Value} -OnClick {
                param($e,$d) Invoke-PASUISafe { $d.S.Set($d.V) } }) 'pas-choice-btn'
        }
    }
    $null=Add-PASUIClass $card 'pas-choice'
}
function Add-PASUIComponentCard {param([string]$C)
    $opts=@(@{Value='0';Label='Not installed'})
    for($i=1;$i -le $script:PASMaxInstances[$C];$i++){$opts+=@{Value=[string]$i;Label=$(if($i -eq 1){'1 server'}else{"$i servers"})}}
    $card=Add-NHKUiColumn -UI $ui -Content {
        $null=Add-NHKUiHtml -UI $ui -Markup ('<div class="pas-choice-t">'+$C+'</div><div class="pas-choice-d">'+(Get-PASUIEscaped $script:PASComponentInfo[$C])+'</div>')
        $null=Add-NHKUiSelect -UI $ui -Bind $state['Count'+$C] -Options $opts
    }
    $null=Add-PASUIClass $card 'pas-comp'
}
function Add-PASUIPage {param([string]$Title,[string]$Text)
    $p=Add-NHKUiColumn -UI $ui -Content {
        $null=Add-NHKUiHeading -UI $ui -Text $Title -Level 2
        $null=Add-NHKUiText -UI $ui -Text $Text -Muted
    }
    $null=Add-PASUIClass $p 'pas-page'
}
function Add-PASUISection {
    <# A titled card. Tone (blue|teal|lavender|amber) gives a faint tinted background and top edge. #>
    param([string]$Title,[string]$Tone,[scriptblock]$Content)
    $card=Add-NHKUiCard -UI $ui -Content {
        $null=Add-NHKUiHeading -UI $ui -Text $Title -Level 3
        $null=& $Content
    }
    $null=Add-PASUIClass $card ('pas-sec pas-tone-'+$Tone)
}
function Add-PASUICredRow {
    <# One server in the per-server credentials list: hostname, optional username, optional password. #>
    param($NameBind,[string]$NameText,[string]$UserKey,[string]$PwKey,$When)
    $null=Add-NHKUiWhen -UI $ui -Bind $When -Content {
        $null=Add-PASUIClass (Add-NHKUiRow -UI $ui -Content {
            if($NameBind){$null=Add-PASUIClass (Add-NHKUiText -UI $ui -Bind $NameBind) 'pas-credhost'}
            else{$null=Add-PASUIClass (Add-NHKUiText -UI $ui -Text $NameText) 'pas-credhost'}
            $null=Add-NHKUiWhen -UI $ui -Bind $state.PerServerUser -Content { $null=Add-NHKUiInput -UI $ui -Bind $state[$UserKey] -Placeholder 'Username' }
            $null=Add-NHKUiWhen -UI $ui -Bind $state.NotLab -Content { $null=Add-NHKUiInput -UI $ui -Bind $state[$PwKey] -Type password -Placeholder 'Password' }
        }) 'pas-credrow'
    }
}
function Add-PASUIPassword {param([string]$Key,[string]$Label,$When)
    if($When){$null=Add-NHKUiWhen -UI $ui -Bind $When -Content { $null=Add-NHKUiInput -UI $ui -Bind $state[$Key] -Label $Label -Type password -Placeholder 'Password' }}
    else{$null=Add-NHKUiInput -UI $ui -Bind $state[$Key] -Label $Label -Type password -Placeholder 'Password'}
}

# ---------------------------------------------------------------- layout
$ui=New-NHKUi -Title 'PASeasyInstall' -Width 1220 -Height 880 -Theme 'cobalt' -Density 'compact' -ExtraCss $css
$backendLabel=if($backendKind -eq 'Mock'){'Mock backend · no servers are contacted'}else{'Live installer · servers are contacted only on Install'}
$backendClass=if($backendKind -eq 'Mock'){'mock'}else{'live'}
$null=Add-NHKUiHtml -UI $ui -Markup ('<header class="pas-top"><div class="pas-brand"><span class="pas-logo">PAS</span><div><div class="pas-brand-t">PASeasyInstall</div><div class="pas-brand-s">CyberArk PAM lab builder · for lab use, production use at your own risk</div></div></div><span class="pas-env '+$backendClass+'">'+(Get-PASUIEscaped $backendLabel)+'</span></header>')

$shell=Add-NHKUiRow -UI $ui -Content {
    $side=Add-NHKUiColumn -UI $ui -Content {
        $null=Add-NHKUiHtml -UI $ui -Markup '<div class="pas-side-h">New installation</div>'
        foreach($st in $script:PASSteps){
            $on=New-PASUIEquals $state.Step $st.N; $off=New-PASUIEquals $state.Step $st.N -Not
            $label=('{0}   {1}' -f $st.N,$st.Title)
            $null=Add-NHKUiWhen -UI $ui -Bind $on -Content { $null=Add-PASUIClass (Add-NHKUiButton -UI $ui -Text $label -Variant primary) 'pas-step active' }
            $null=Add-NHKUiWhen -UI $ui -Bind $off -Content {
                $null=Add-PASUIClass (Add-NHKUiButton -UI $ui -Text $label -Variant quiet -Data $st.N -OnClick {
                    param($e,$n) Invoke-PASUISafe { Set-PASUIStep $n } }) 'pas-step'
            }
        }
        $null=Add-NHKUiHtml -UI $ui -Markup '<div class="pas-side-foot">Nothing changes on any server until you click <strong>Install</strong> on step 6.<br><br>For lab use. Production use is at your own risk.</div>'
    }
    $null=Add-PASUIClass $side 'pas-side'

    $main=Add-NHKUiColumn -UI $ui -Content {

        # 1 Project & media
        $null=Add-NHKUiWhen -UI $ui -Bind (New-PASUIEquals $state.Step 1) -Content {
            Add-PASUIPage 'Project & media' 'Name the environment and add the installer files. What you can install is worked out from them.'
            $null=Add-NHKUiText -UI $ui -Text 'PASeasyInstall builds CyberArk PAM labs. For lab use: production use is at your own risk. Not affiliated with or endorsed by CyberArk.' -Muted
            Add-PASUISection 'Project' 'teal' {
                $null=Add-NHKUiInput -UI $ui -Bind $state.Name -Label 'Environment name' -Placeholder 'e.g. Lab01'
                $null=Add-PASUIClass (Add-NHKUiRow -UI $ui -Content {
                    $null=Add-NHKUiHtml -UI $ui -Markup '<span class="pas-kv-k">Project file</span>'
                    $null=Add-PASUIClass (Add-NHKUiText -UI $ui -Bind $state.ProjectPath) 'pas-path'
                    $null=Add-PASUIClass (Add-NHKUiButton -UI $ui -Text 'Change folder…' -Variant quiet -OnClick { param($e,$d) Invoke-PASUISafe {
                        $p=@(Show-PASUIDialog -Kind ChooseFolder -Title 'Folder for the project file'); if($p.Count){$state.ProjectDir.Set([string]$p[0])} } }) 'pas-browse'
                }) 'pas-kv'
                $null=Add-NHKUiText -UI $ui -Text 'Addresses, paths and choices are saved here. Passwords never are.' -Muted
            }
            Add-PASUISection 'Installer media, license and keys' 'blue' {
                $null=Add-NHKUiHtml -UI $ui -Markup '<div class="pas-drop" id="pas-dropzone" data-nativehtmlkit-drop="files"><div class="pas-drop-t">Drop ZIP files or folders here</div><div class="pas-drop-d">The CyberArk bundle, single component ZIPs, the license (.xml or licenses.zip) and recpub.key. Bundles are read without extracting.</div></div>'
                $null=Add-NHKUiRow -UI $ui -Content {
                    $null=Add-NHKUiButton -UI $ui -Text 'Add files…' -Variant secondary -OnClick { param($e,$d) Invoke-PASUISafe { Add-PASUIMedia @(Show-PASUIDialog -Kind OpenFiles -Title 'Installer files, license and keys' -Multiple) } }
                    $null=Add-NHKUiButton -UI $ui -Text 'Add folder…' -Variant secondary -OnClick { param($e,$d) Invoke-PASUISafe { Add-PASUIMedia @(Show-PASUIDialog -Kind ChooseFolder -Title 'Folder with installer media') } }
                    $null=Add-NHKUiButton -UI $ui -Text 'Clear' -Variant quiet -OnClick { param($e,$d) Invoke-PASUISafe { Clear-PASUIMedia } }
                }
                $script:pasMedia=Add-NHKUiHtml -UI $ui -Markup ''
                # Chosen installer per kind, only where several files were found; recommended one first.
                $null=Add-PASUIClass (Add-NHKUiGrid -UI $ui -Content {
                    foreach($m in $script:PASUIMediaOrder){
                        $null=Add-NHKUiWhen -UI $ui -Bind $state['Found'+$m.C] -Content {
                            $script:pasChoiceNodes[$m.C]=Add-NHKUiSelect -UI $ui -Bind $state['Choice'+$m.C] -Label ($m.L+' — choose a different file') -Options @(@{Value='0';Label='—'})
                        }
                    }
                }) 'pas-choicegrid'
            }
        }

        # 2 What to install
        $null=Add-NHKUiWhen -UI $ui -Bind (New-PASUIEquals $state.Step 2) -Content {
            Add-PASUIPage 'What to install' 'Preselected from your media. Change anything you need.'
            Add-PASUISection 'Vault' 'blue' {
                $null=Add-PASUIClass (Add-NHKUiRow -UI $ui -Content {
                    Add-PASUIChoice 'Primary' 'Primary Vault' 'One new Vault server.'
                    Add-PASUIChoice 'PrimaryDR' 'Primary + DR Vault' 'A new Primary and a standby DR Vault, replicated from day one.'
                    Add-PASUIChoice 'Existing' 'Existing Vault' 'No Vault install. Components register to a Vault that already runs.'
                }) 'pas-choices'
            }
            Add-PASUISection 'Components' 'teal' {
                $null=Add-NHKUiText -UI $ui -Text 'How many servers of each. You give each one a hostname on the next step.' -Muted
                $null=Add-PASUIClass (Add-NHKUiRow -UI $ui -Content { foreach($c in $script:PASComponents){Add-PASUIComponentCard $c} }) 'pas-comps'
                $script:pasCompMedia=Add-NHKUiHtml -UI $ui -Markup ''
            }
            $null=Add-NHKUiWhen -UI $ui -Bind $state.AnyPSMP -Content {
                Add-PASUISection 'License agreement' 'amber' {
                    $null=Add-NHKUiCheckbox -UI $ui -Bind $state.AcceptEula -Label 'I accept the CyberArk license agreement (EULA) for the PSMP installer'
                    $null=Add-NHKUiText -UI $ui -Text 'The PSMP installer runs unattended and asks for this acceptance up front. The other installers include it in their silent setup.' -Muted
                }
            }
            $null=Add-PASUIClass (Add-NHKUiText -UI $ui -Bind $state.ScopeSummary) 'pas-summary'
        }

        # 3 Servers
        $null=Add-NHKUiWhen -UI $ui -Bind (New-PASUIEquals $state.Step 3) -Content {
            Add-PASUIPage 'Servers' 'Where everything goes. Use IP addresses or DNS names the controller can reach.'
            Add-PASUISection 'This computer (the controller)' 'amber' {
                $null=Add-NHKUiHtml -UI $ui -Markup '<div class="pas-explain">The <strong>controller</strong> is the machine running PASeasyInstall right now. It copies the installers to each server and runs the installation there remotely (WinRM for Windows, SSH for Linux). Its address is added to the Vault firewall so it can manage the Vault during installation. Detected automatically; change it if the servers reach this computer on a different address.</div>'
                $null=Add-NHKUiGrid -UI $ui -Content {
                    $null=Add-NHKUiInput -UI $ui -Bind $state.Controller -Label 'Controller address (this computer)' -Placeholder '10.10.0.10'
                }
            }
            Add-PASUISection 'Vault servers' 'blue' {
                $null=Add-NHKUiGrid -UI $ui -Content {
                    $null=Add-NHKUiWhen -UI $ui -Bind $state.InstallsVault -Content { $null=Add-NHKUiInput -UI $ui -Bind $state.Primary -Label 'Primary Vault address' -Placeholder '10.10.0.11' }
                    $null=Add-NHKUiWhen -UI $ui -Bind $state.ShowDR -Content { $null=Add-NHKUiInput -UI $ui -Bind $state.DR -Label 'DR Vault address' -Placeholder '10.10.0.12' }
                    $null=Add-NHKUiWhen -UI $ui -Bind $state.IsExisting -Content { $null=Add-NHKUiInput -UI $ui -Bind $state.ExistingVault -Label 'Existing Vault address' -Placeholder '10.10.0.11' }
                }
            }
            $null=Add-NHKUiWhen -UI $ui -Bind $state.AnyComponent -Content {
                Add-PASUISection 'Component servers' 'teal' {
                    $null=Add-NHKUiText -UI $ui -Text 'Give each server its hostname and address. Instances with the same address are installed on one server.' -Muted
                    foreach($c in $script:PASComponents){
                        $null=Add-NHKUiWhen -UI $ui -Bind $state['Any'+$c] -Content {
                            $null=Add-NHKUiHeading -UI $ui -Text $c -Level 4
                            $null=Add-PASUIClass (Add-NHKUiGrid -UI $ui -Content {
                                for($i=1;$i -le $script:PASMaxInstances[$c];$i++){
                                    $ph=if($c -eq 'PSMP'){"10.10.0.3$i"}else{"10.10.0.2$i"}
                                    $null=Add-NHKUiWhen -UI $ui -Bind $state["Show$c$i"] -Content {
                                        $null=Add-PASUIClass (Add-NHKUiRow -UI $ui -Content {
                                            $null=Add-NHKUiInput -UI $ui -Bind $state["Name$c$i"] -Label 'Hostname' -Placeholder ('{0}{1:00}' -f $c,$i)
                                            $null=Add-NHKUiInput -UI $ui -Bind $state["Addr$c$i"] -Label 'Address' -Placeholder $ph
                                        }) 'pas-inst'
                                    }
                                }
                            }) 'pas-instgrid'
                        }
                    }
                }
            }
        }

        # 4 Credentials
        $null=Add-NHKUiWhen -UI $ui -Bind (New-PASUIEquals $state.Step 4) -Content {
            Add-PASUIPage 'Credentials' 'Accounts and passwords for the servers and the Vault. Passwords stay in memory for this session only; they are never saved.'
            Add-PASUISection 'Accounts' 'teal' {
                $null=Add-NHKUiGrid -UI $ui -Content {
                    $null=Add-NHKUiInput -UI $ui -Bind $state.User -Label 'Default username on Windows servers' -Placeholder 'Administrator'
                    $null=Add-NHKUiWhen -UI $ui -Bind $state.AnyLinux -Content {
                        $null=Add-NHKUiInput -UI $ui -Bind $state.LinuxUser -Label 'Default username on Linux servers' -Placeholder 'root'
                    }
                }
                $null=Add-NHKUiText -UI $ui -Text 'The local administrator account the controller signs in with on each server.' -Muted
                $null=Add-NHKUiCheckbox -UI $ui -Bind $state.PerServerUser -Label 'Use a different username on some servers'
            }
            Add-PASUISection 'Passwords' 'amber' {
                $null=Add-NHKUiCheckbox -UI $ui -Bind $state.LabMode -Label 'Lab mode: use one password for everything (insecure)'
                $null=Add-NHKUiWhen -UI $ui -Bind $state.LabMode -Content {
                    $null=Add-NHKUiGrid -UI $ui -Content { $null=Add-NHKUiInput -UI $ui -Bind $state.Universal -Label 'Universal password' -Type password }
                    $null=Add-NHKUiHtml -UI $ui -Markup '<div class="pas-msg warn"><span class="pas-msg-icon">!</span><span>Every server account, the Vault Administrator, Master and DR user get this same password. Use only in disposable labs.</span></div>'
                }
                $null=Add-NHKUiWhen -UI $ui -Bind $state.NotLab -Content {
                    $null=Add-NHKUiText -UI $ui -Text 'Enter a password for each server below, and for the Vault accounts.' -Muted
                }
            }
            $null=Add-NHKUiWhen -UI $ui -Bind $state.ShowPerServer -Content {
                Add-PASUISection 'Per server' 'blue' {
                    $null=Add-PASUIClass (Add-NHKUiRow -UI $ui -Content {
                        $null=Add-PASUIClass (Add-NHKUiText -UI $ui -Text 'Hostname') 'pas-credhost'
                        $null=Add-NHKUiWhen -UI $ui -Bind $state.PerServerUser -Content { $null=Add-NHKUiText -UI $ui -Text 'Username' }
                        $null=Add-NHKUiWhen -UI $ui -Bind $state.NotLab -Content { $null=Add-NHKUiText -UI $ui -Text 'Password' }
                    }) 'pas-credrow pas-credhead'
                    Add-PASUICredRow $null 'Primary Vault' 'UserPrimary' 'PwPrimary' $state.InstallsVault
                    Add-PASUICredRow $null 'DR Vault' 'UserDR' 'PwDR' $state.ShowDR
                    foreach($c in $script:PASComponents){
                        for($i=1;$i -le $script:PASMaxInstances[$c];$i++){Add-PASUICredRow $state["Name$c$i"] '' "User$c$i" "Pw$c$i" $state["Show$c$i"]}
                    }
                    $null=Add-NHKUiText -UI $ui -Text 'Hostnames come from the Servers step. Instances sharing a server use the first one''s username and password.' -Muted
                }
            }
            $null=Add-NHKUiWhen -UI $ui -Bind $state.NotLab -Content {
                Add-PASUISection 'Vault accounts' 'lavender' {
                    $null=Add-NHKUiGrid -UI $ui -Content {
                        Add-PASUIPassword 'PwVaultAdmin' 'Vault Administrator password' $null
                        Add-PASUIPassword 'PwMaster' 'Vault Master password' $state.InstallsVault
                        Add-PASUIPassword 'PwDRUser' 'DR user password' $state.ShowDR
                    }
                }
            }
        }

        # 5 Review
        $null=Add-NHKUiWhen -UI $ui -Bind (New-PASUIEquals $state.Step 5) -Content {
            Add-PASUIPage 'Review plan' 'Everything that will happen, in order. Nothing has been sent to any server yet.'
            Add-PASUISection 'Plan' 'blue' {
                $script:pasReview=Add-NHKUiHtml -UI $ui -Markup '<div class="pas-empty">Preparing…</div>'
                $null=Add-NHKUiButton -UI $ui -Text 'Re-check' -Variant quiet -OnClick { param($e,$d) Invoke-PASUISafe { $work.PreviewHash=''; Set-PASUIStep 5 } }
            }
        }

        # 6 Install
        $null=Add-NHKUiWhen -UI $ui -Bind (New-PASUIEquals $state.Step 6) -Content {
            Add-PASUIPage 'Install' 'The controller runs the installation on the servers. You can follow progress here.'
            Add-PASUISection 'Ready to install' 'teal' {
                $null=Add-PASUIClass (Add-NHKUiRow -UI $ui -Content {
                    $script:pasReadiness=Add-NHKUiHtml -UI $ui -Markup ''
                    $null=Add-PASUIClass (Add-NHKUiButton -UI $ui -Text 'Install' -Variant primary -DisabledState $state.InstallBlocked -OnClick { param($e,$d) Invoke-PASUISafe { Start-PASUIInstall } }) 'pas-cta'
                }) 'pas-readyrow'
            }
            Add-PASUISection 'Progress' 'blue' {
                $script:pasTimeline=Add-NHKUiHtml -UI $ui -Markup (ConvertTo-PASUIDashboardHtml -Snapshot $null)
            }
        }

        $script:pasMessage=Add-NHKUiHtml -UI $ui -Markup (ConvertTo-PASUIMessageHtml -Kind info -Text 'Name the environment and add the installer media. No server is contacted until you click Install.')
        $nav=Add-NHKUiRow -UI $ui -Content {
            $null=Add-NHKUiButton -UI $ui -Text '←  Back' -Variant secondary -DisabledState $state.FirstStep -OnClick { param($e,$d) Invoke-PASUISafe { Set-PASUIStep ([int]$state.Step.Value-1) } }
            $null=Add-NHKUiWhen -UI $ui -Bind $state.NotLastStep -Content {
                $null=Add-NHKUiButton -UI $ui -Bind $state.NextLabel -Variant primary -OnClick { param($e,$d) Invoke-PASUISafe { Set-PASUIStep ([int]$state.Step.Value+1) } }
            }
        }
        $null=Add-PASUIClass $nav 'pas-nav'
    }
    $null=Add-PASUIClass $main 'pas-main'
}
$null=Add-PASUIClass $shell 'pas-shell'
Update-PASUIMediaView
Update-PASUIReadiness

# ---------------------------------------------------------------- run
try{
    $null=Start-NHKUi -UI $ui -Application $pasApp
    Register-NativeHTMLKitNotification -Application $pasApp -Method 'app.shutdown' -Callback {param($m) $script:pasAlive=$false}
    Register-NativeHTMLKitNotification -Application $pasApp -Method 'window.event' -Callback {param($m) if([string]$m.type -eq 'closed'){$script:pasAlive=$false}}
    # External file/folder drops onto the element marked data-nativehtmlkit-drop="files" (SDK document event).
    $null=Register-NativeHTMLKitDocumentEvent -Document $ui.Document -Type drop -Callback {
        param($evt)
        $paths=@(); $prop=$evt.PSObject.Properties['paths']; if($prop){$paths=@($prop.Value)}
        if($paths.Count){Invoke-PASUISafe { Add-PASUIMedia ([string[]]$paths) }}
    }
    if($Config){Invoke-PASUISafe { Import-PASUIProject $Config }}
    while($script:pasAlive){
        $null=Wait-NativeHTMLKit -Application $pasApp -TimeoutMilliseconds 250
        if($work.RunId -and $state.Busy.Value -and ([datetime]::UtcNow-$work.LastRefresh).TotalSeconds -ge 1){
            $work.LastRefresh=[datetime]::UtcNow
            try{Update-PASUIDashboard}catch{Write-PASUIMessage error ('Unable to refresh progress: '+$_.Exception.Message)}
        }
    }
}finally{
    foreach($c in $script:pasComputed){$c.Dispose()}
    Stop-NHKUi -UI $ui
    Close-NativeHTMLKit -Application $pasApp
}
