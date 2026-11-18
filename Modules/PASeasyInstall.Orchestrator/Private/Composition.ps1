# Deployment composition for the desktop UI and scripted callers: one configuration for a new
# Primary (+DR) or an existing Vault plus any number of component instances. Pure configuration
# work: no server is contacted. The only side effect is extracting a selected installer that lives
# inside a ZIP bundle into the controller's media cache (read-only on the source).

$script:PASComponentTypes=@('PVWA','CPM','PSM','PSMP')   # PTA: not part of this release; module kept for future tests
$script:PASLinuxTypes=@('PSMP','PTA')
$script:PASMaxInstances=@{PVWA=4;CPM=4;PSM=4;PSMP=4;PTA=1}
# Engine/journal names that must never be used as instance ids (event mapping and credential aliases).
$script:PASReservedIds=@('vault','dr','primary','primary_final','dr_final','vault01','dr01','primaryadmin','dradmin','controller')

function Get-PASOrchestratorDataRoot {
    if($env:PAS_EASY_DATA_ROOT){return [IO.Path]::GetFullPath($env:PAS_EASY_DATA_ROOT)}
    if($env:OS -eq 'Windows_NT'){return (Join-Path $env:LOCALAPPDATA 'PASeasyInstall')}
    return (Join-Path $HOME '.local/share/PASeasyInstall')
}
function Get-PASSafeName {
    param([string]$Value,[int]$Max=40)
    $s=([string]$Value).Trim().ToLowerInvariant() -replace '[^a-z0-9_-]','-'
    $s=$s.Trim('-')
    if(-not $s){$s='server'}
    if($s -notmatch '^[a-z]'){$s='s-'+$s}
    if($s.Length -gt $Max){$s=$s.Substring(0,$Max).TrimEnd('-')}
    return $s
}
function Get-PASMediaItemValue {
    param($Item,[string]$Name)
    if($null -eq $Item){return ''}
    if($Item -is [string]){if($Name -eq 'Path'){return $Item};return ''}
    if($Item -is [System.Collections.IDictionary]){
        foreach($k in @($Name,$Name.ToLowerInvariant())){if($Item.Contains($k)){return [string]$Item[$k]}}
        return ''
    }
    $p=$Item.PSObject.Properties[$Name];if($p){return [string]$p.Value}
    return ''
}
function Resolve-PASMediaItemPath {
    <# A plain file is used where it is. An entry inside a ZIP bundle is extracted once into
       <DataRoot>/MediaCache/<key>/<entry file name>; the key covers bundle path, entry, size and time. #>
    param($Item,[string]$DataRoot=(Get-PASOrchestratorDataRoot))
    $path=Get-PASMediaItemValue $Item 'Path'
    $entry=Get-PASMediaItemValue $Item 'Entry'
    if(-not $path){return ''}
    if(-not $entry){return $path}
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Media bundle not found: $path"}
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $info=Get-Item -LiteralPath $path
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($info.FullName+'|'+$entry+'|'+$info.Length+'|'+$info.LastWriteTimeUtc.Ticks))))).Replace('-','').Substring(0,24).ToLowerInvariant()}
    finally{$sha.Dispose()}
    $name=[IO.Path]::GetFileName($entry.Replace('\','/'))
    if(-not $name -or $name -in @('.','..')){throw "Unsafe bundle entry name: $entry"}
    $dir=Join-Path (Join-Path $DataRoot 'MediaCache') $key
    $target=Join-Path $dir $name
    $zip=[IO.Compression.ZipFile]::OpenRead($info.FullName)
    try{
        $e=@($zip.Entries|Where-Object {$_.FullName -eq $entry})
        if($e.Count -ne 1){throw "Entry '$entry' not found once in $($info.Name)"}
        if((Test-Path -LiteralPath $target -PathType Leaf) -and (Get-Item -LiteralPath $target).Length -eq $e[0].Length){return $target}
        if(-not(Test-Path -LiteralPath $dir)){New-Item -ItemType Directory -Path $dir -Force|Out-Null}
        $tmp=$target+'.'+[guid]::NewGuid().ToString('N')+'.part'
        try{
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e[0],$tmp,$true)
            if((Get-Item -LiteralPath $tmp).Length -ne $e[0].Length){throw "Extracted size mismatch for $entry"}
            if(Test-Path -LiteralPath $target){Remove-Item -LiteralPath $target -Force}
            [IO.File]::Move($tmp,$target)
        }finally{if(Test-Path -LiteralPath $tmp){Remove-Item -LiteralPath $tmp -Force}}
    }finally{$zip.Dispose()}
    return $target
}
function Get-PASCommonDirectory {
    param([string[]]$Paths)
    $dirs=@($Paths|Where-Object {$_}|ForEach-Object {
        $full=[IO.Path]::GetFullPath($_)
        if(Test-Path -LiteralPath $full -PathType Container){$full}else{[IO.Path]::GetDirectoryName($full)}
    })
    if(-not $dirs.Count){return ''}
    $common=$dirs[0]
    foreach($d in $dirs){
        while($common -and -not ($d.Equals($common,[StringComparison]::OrdinalIgnoreCase) -or $d.StartsWith($common.TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))){
            $parent=[IO.Path]::GetDirectoryName($common)
            if(-not $parent -or $parent -eq $common){$common='';break}
            $common=$parent
        }
    }
    return $common
}

function New-PASDeploymentConfiguration {
    <#
    .SYNOPSIS
    Composes one deployment configuration: Vault (Primary, Primary + DR, or an existing Vault) and any
    number of component instances. Nothing is contacted or installed.
    .PARAMETER Instances
    @( @{Type='PVWA';Name='PVWA01';Address='10.0.0.21';Username=''} ). Type PVWA|CPM|PSM|PSMP|PTA
    (PTA: one). Name is the server hostname shown in the UI; the configuration id is its lowercase
    form. Instances with the same address share one server, named after the first instance.
    Linux instances may carry IdentityFile/KnownHostsFile; otherwise the controller's per-environment
    key under <DataRoot>/ssh/<environment>/ is used (created and authorised on first install).
    .PARAMETER Media
    @{Vault=item;PACLI=item;DR=item;PVWA=item;...;License=item;RecoveryKey=item}: inventory items from
    Get-PASMediaInventory/Get-PASMediaSelection, @{Path;Entry} or plain paths.
    .PARAMETER SecurityProfile
    Lab adds the explicit, audited lab deviations a template-built lab needs (self-signed WinRM
    certificates, RDP to the Vault from the controller, self-signed PVWA certificate pinned by CPM).
    #>
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Environment,
        [Parameter(Mandatory)][ValidateSet('Primary','PrimaryDR','Existing')][string]$VaultMode,
        [object[]]$Instances=@(),[AllowEmptyString()][string]$ControllerAddress='',
        [AllowEmptyString()][string]$PrimaryAddress='',[AllowEmptyString()][string]$DRAddress='',
        [AllowEmptyString()][string]$ExistingVaultAddress='',
        [string]$Username='Administrator',[string]$LinuxUsername='root',[hashtable]$Media=@{},
        [ValidateSet('Sequential','Parallel')][string]$ExecutionMode='Sequential',
        [AllowEmptyString()][string]$PrimaryUsername='',[AllowEmptyString()][string]$DRUsername='',
        [ValidateSet('Secure','Lab')][string]$SecurityProfile='Secure',[switch]$AcceptEula,
        [string]$DataRoot=(Get-PASOrchestratorDataRoot))
    $lab=($SecurityProfile -eq 'Lab')
    $overrides=[ordered]@{}
    $c=[ordered]@{
        schemaVersion=2; name=$Environment.Trim(); mediaRoot=''; controllerAddress=$ControllerAddress.Trim()
        security=[ordered]@{profile=$SecurityProfile;overrides=$overrides}
        vault=[ordered]@{address='';adminUser='Administrator';secretRef='VaultAdmin';masterSecretRef='VaultMaster';drSecretRef='DRPassword';existing=($VaultMode -eq 'Existing')}
        activeDirectory=[ordered]@{mode='None';host='dc01';domain='pam.lab';join=@();joinUser='PAM\Administrator';createTestAccounts=$false}
        hosts=[ordered]@{}; components=@(); media=[ordered]@{}; options=[ordered]@{}
        execution=[ordered]@{mode=$ExecutionMode}
    }
    $components=New-Object System.Collections.ArrayList
    $anyWindows=$false
    if($VaultMode -eq 'Existing'){
        $c.vault.address=$ExistingVaultAddress.Trim()
    }else{
        # The Vault management endpoint is bound to one LOCAL account: plain name, no '.\' prefix.
        $pu=if($PrimaryUsername){$PrimaryUsername}else{$Username}; $pu=([string]$pu).Trim(); if($pu.StartsWith('.\')){$pu=$pu.Substring(2)}
        $c.vault.address=$PrimaryAddress.Trim(); $c.vault.managementHost='vault01'
        $c.hosts['vault01']=[ordered]@{address=$PrimaryAddress.Trim();os='Windows';user=$pu;credentialRef='vault01'}
        [void]$components.Add([ordered]@{id='vault';name='Vault';type='Vault';host='vault01';variant='Standalone'})
        if($VaultMode -eq 'PrimaryDR'){
            $du=if($DRUsername){$DRUsername}else{$pu}; $du=([string]$du).Trim(); if($du.StartsWith('.\')){$du=$du.Substring(2)}
            $c.hosts['dr01']=[ordered]@{address=$DRAddress.Trim();os='Windows';user=$du;credentialRef='dr01'}
            [void]$components.Add([ordered]@{id='dr';name='DR';type='DRVault';host='dr01';variant='StandardDR'})
        }
        $anyWindows=$true
        # The media folder is the common folder of the Vault media (it also holds the VC++ runtimes and
        # the Vault Ansible role the backend takes PAKeyGen and response templates from).
        $vaultItems=@('Vault','PACLI','DR','KeyGen','License','RecoveryKey'|Where-Object {$Media.ContainsKey($_)}|ForEach-Object {Get-PASMediaItemValue $Media[$_] 'Path'})
        $c.mediaRoot=Get-PASCommonDirectory $vaultItems
        foreach($pair in @(@('Vault','ServerZip'),@('PACLI','PACLIZip'),@('DR','DisasterRecoveryZip'))){
            if(-not $Media.ContainsKey($pair[0])){continue}
            if($pair[0] -eq 'DR' -and $VaultMode -ne 'PrimaryDR'){continue}
            # A package inside the bundle is found by the backend's own bundle resolution.
            if(-not (Get-PASMediaItemValue $Media[$pair[0]] 'Entry')){$c.media[$pair[1]]=Get-PASMediaItemValue $Media[$pair[0]] 'Path'}
        }
        if($Media.ContainsKey('License')){$c.media.License=Resolve-PASMediaItemPath $Media.License $DataRoot}
        if($Media.ContainsKey('RecoveryKey')){$c.media.PublicRecoveryKey=Resolve-PASMediaItemPath $Media.RecoveryKey $DataRoot}
        if($lab){$overrides['Vault.AllowRDP']=$true}
    }
    $envSafe=Get-PASSafeName $Environment 40
    $sshDir=Join-Path (Join-Path $DataRoot 'ssh') $envSafe
    $byAddress=@{}; $usedIds=@{}
    foreach($r in $script:PASReservedIds){$usedIds[$r]=$true}
    $firstPvwa=''
    $count=@{}
    foreach($inst in @($Instances|Where-Object {$_})){
        $type=[string](Get-PASMediaItemValue $inst 'Type')
        if($type -notin $script:PASComponentTypes){throw "Unknown component type: $type"}
        $count[$type]=1+[int]$count[$type]
        $name=([string](Get-PASMediaItemValue $inst 'Name')).Trim(); if(-not $name){$name=('{0}{1:00}' -f $type,$count[$type])}
        $addr=([string](Get-PASMediaItemValue $inst 'Address')).Trim()
        $os=if($type -in $script:PASLinuxTypes){'Linux'}else{'Windows'}
        $user=([string](Get-PASMediaItemValue $inst 'Username')).Trim()
        if(-not $user){$user=if($os -eq 'Linux'){$LinuxUsername}else{$Username}}
        $id=Get-PASSafeName $name 40; $base=$id; $n=2
        while($usedIds.ContainsKey($id)){$id=('{0}-{1}' -f $base.Substring(0,[Math]::Min($base.Length,36)),$n);$n++}
        $usedIds[$id]=$true
        $addrKey=$addr.ToLowerInvariant()
        if($addr -and $byAddress.ContainsKey($addrKey)){$hostId=$byAddress[$addrKey]}
        else{
            $hostId=$id
            $h=[ordered]@{address=$addr;os=$os;user=$user;credentialRef=$hostId}
            if($os -eq 'Linux'){
                $identity=[string](Get-PASMediaItemValue $inst 'IdentityFile'); $known=[string](Get-PASMediaItemValue $inst 'KnownHostsFile')
                $h.identityFile=$(if($identity){$identity}else{Join-Path $sshDir 'id_ed25519'})
                $h.knownHostsFile=$(if($known){$known}else{Join-Path $sshDir 'known_hosts'})
            }else{$anyWindows=$true}
            $c.hosts[$hostId]=$h
            if($addr){$byAddress[$addrKey]=$hostId}
        }
        $mediaPath=''
        if($Media.ContainsKey($type)){$mediaPath=Resolve-PASMediaItemPath $Media[$type] $DataRoot}
        $options=[ordered]@{}
        switch($type){
            'PVWA'{
                $options.pvwaUrl='https://'+$name+'/PasswordVault'
                if($lab){$options.createLabCertificate=$true}
                if(-not $firstPvwa){$firstPvwa=$id}
            }
            'PSMP'{if($AcceptEula){$options.acceptEula=$true}}
            'PTA'{if($lab){$overrides['PTA.GenerateLabCA']=$true}}
        }
        $entry=[ordered]@{id=$id;name=$name;type=$type;host=$hostId;variant='Standard';media=$mediaPath;options=$options}
        if($user -ne [string]$c.hosts[$hostId].user){$entry.user=$user}
        [void]$components.Add($entry)
    }
    # CPM pins the self-signed certificate of the first PVWA installed in this deployment; the
    # installer reads it from that PVWA over the authenticated management channel at install time.
    if($lab -and $firstPvwa){
        foreach($e in @($components|Where-Object {$_.type -eq 'CPM'})){$e.options.pvwaTrustFrom=$firstPvwa}
        if(@($components|Where-Object {$_.type -eq 'CPM'}).Count){$overrides['CPM.AllowPinnedLeafTrust']=$true}
    }
    if($lab -and $anyWindows){$overrides['WinRM.SkipCACheck']=$true;$overrides['WinRM.SkipCNCheck']=$true}
    $c.components=@($components.ToArray())
    return $c
}

function Test-PASOrchestratorRules {
    <# Composition rules on top of the engine validation. Returns @{Issues;Warnings}. #>
    param($Configuration)
    $issues=@();$warnings=@()
    $comps=@($Configuration.components|Where-Object {$_})
    foreach($t in $script:PASComponentTypes){
        $n=@($comps|Where-Object {$_.type -eq $t}).Count
        if($n -gt $script:PASMaxInstances[$t]){$issues+="At most $($script:PASMaxInstances[$t]) $t server(s) are supported"}
    }
    $ids=@{};foreach($e in $comps){$ids[[string]$e.id]=$e}
    foreach($e in $comps){
        $opts=$null;if($e -is [System.Collections.IDictionary] -and $e.Contains('options')){$opts=$e.options}
        $label=if($e -is [System.Collections.IDictionary] -and $e.Contains('name') -and $e.name){[string]$e.name}else{[string]$e.id}
        if($e.type -eq 'PSMP' -and -not ($opts -and $opts.Contains('acceptEula') -and [bool]$opts.acceptEula)){
            $issues+="Accept the CyberArk license agreement (EULA) for the PSMP installer ($label)"
        }
        if($opts -and $opts.Contains('pvwaTrustFrom')){
            $src=[string]$opts.pvwaTrustFrom
            if(-not $ids.ContainsKey($src) -or $ids[$src].type -ne 'PVWA'){$issues+="$label trusts PVWA '$src', which is not part of this deployment"}
            elseif(-not $Configuration.Contains('execution')){$issues+="$label pins a PVWA certificate captured at install time; start it with Start-PASEnvironment"}
        }
        if($e -is [System.Collections.IDictionary] -and $e.Contains('user') -and $e.user -and $Configuration.hosts.Contains([string]$e.host) -and [string]$Configuration.hosts[[string]$e.host].user -ne [string]$e.user){
            $issues+="$label shares a server with $($e.host) but uses account '$($e.user)' instead of '$($Configuration.hosts[[string]$e.host].user)'"
        }
    }
    if($Configuration.Contains('execution')){
        $mode=[string]$Configuration.execution.mode
        if($mode -notin @('Sequential','Parallel')){$issues+="execution.mode must be Sequential or Parallel"}
    }
    if(@($comps|Where-Object {$_.type -in @('Vault','DRVault')}).Count -eq 0 -and $comps.Count -eq 0){$issues+='Nothing selected to install'}
    return @{Issues=@($issues);Warnings=@($warnings)}
}

function Add-PASPlanDetail {
    <# Display fields the desktop needs (instance name, address, OS, installer file). #>
    param($Plan,$Configuration)
    foreach($item in @($Plan.Items)){
        $e=@($Configuration.components|Where-Object {$_.id -eq $item.Id})[0]
        $h=$Configuration.hosts[[string]$item.Host]
        $name=if($e -is [System.Collections.IDictionary] -and $e.Contains('name') -and $e.name){[string]$e.name}else{[string]$item.Id}
        $media=''
        if($item.Type -in @('Vault','DRVault')){
            $key=if($item.Type -eq 'Vault'){'ServerZip'}else{'DisasterRecoveryZip'}
            if($Configuration.media -and $Configuration.media.Contains($key)){$media=[IO.Path]::GetFileName([string]$Configuration.media[$key])}
            elseif($Configuration.mediaRoot){$media='from '+[IO.Path]::GetFileName(([string]$Configuration.mediaRoot).TrimEnd('\','/'))}
        }elseif($e -and $e.Contains('media') -and $e.media){$media=[IO.Path]::GetFileName([string]$e.media)}
        $item|Add-Member -NotePropertyName Name -NotePropertyValue $name -Force
        $item|Add-Member -NotePropertyName Address -NotePropertyValue ([string]$h.address) -Force
        $item|Add-Member -NotePropertyName Os -NotePropertyValue ([string]$h.os) -Force
        $item|Add-Member -NotePropertyName Media -NotePropertyValue $media -Force
    }
    $existing=if($Configuration.vault.existing){[string]$Configuration.vault.address}else{''}
    $Plan|Add-Member -NotePropertyName ExistingVault -NotePropertyValue $existing -Force
    if($Configuration.Contains('execution') -and $Configuration.execution.mode){$Plan.ExecutionMode=[string]$Configuration.execution.mode}
    return $Plan
}
