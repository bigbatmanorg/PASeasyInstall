# Desired-state configuration. Pure data; no executable strings or plaintext secrets.
function Read-PASConfiguration {
    param([string]$Path,$Configuration)
    if($Path -and $null -ne $Configuration){throw 'Supply -Config OR -Configuration, not both'}
    if($Path){
        if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){throw "Configuration file not found: $Path"}
        $Configuration=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    if($null -eq $Configuration){throw 'Deployment configuration required'}
    $result=ConvertTo-PASHashtable $Configuration
    if($result -isnot [System.Collections.IDictionary]){throw 'Configuration root must be an object'}
    return $result
}
function Get-PASPTASyslogHost {
    param([hashtable]$Configuration)
    if(-not @($Configuration.components|Where-Object {$_.type -eq 'PTA'}).Count){return ''}
    if($Configuration.security.profile -eq 'Lab' -and [bool](Get-PASValue $Configuration.security.overrides 'PTA.SkipVaultSyslog' $false)){return ''}
    $selected=[string](Get-PASValue $Configuration.vault 'managementHost' '')
    if($selected){return $selected}
    $primary=@($Configuration.components|Where-Object {$_.type -eq 'Vault'})
    if($primary.Count -eq 1){return [string]$primary[0].host}
    $matching=@($Configuration.hosts.Keys|Where-Object {$Configuration.hosts[$_].os -eq 'Windows' -and $Configuration.hosts[$_].address -eq $Configuration.vault.address})
    if($matching.Count -eq 1){return [string]$matching[0]}
    return ''
}
function Get-PASDeploymentHostIds {
    param([hashtable]$Configuration)
    return @(@($Configuration.components|ForEach-Object {[string]$_.host})+@($Configuration.activeDirectory.join)+@((Get-PASPTASyslogHost $Configuration))|Where-Object {$_}|Sort-Object -Unique)
}
function New-PASConfigurationTemplate {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([ValidateSet('Vault','VaultDR','FullLab','ADOnly','ExistingVault','DomainJoin')][string]$Template='FullLab',
        [Parameter(Mandatory)][string]$Path,[switch]$Force)
    $hosts=@{
        'vault01'=@{address='192.0.2.11';os='Windows';user='Administrator';credentialRef='vault01'}
        'dr01'=@{address='192.0.2.12';os='Windows';user='Administrator';credentialRef='dr01'}
        'pam01'=@{address='192.0.2.13';os='Windows';user='Administrator';credentialRef='pam01'}
        'psm01'=@{address='192.0.2.14';os='Windows';user='Administrator';credentialRef='psm01'}
        'psmp01'=@{address='192.0.2.15';os='Linux';user='root';credentialRef='psmp01'}
        'pta01'=@{address='192.0.2.16';os='Linux';user='root';credentialRef='pta01'}
        'dc01'=@{address='192.0.2.10';os='Windows';user='Administrator';credentialRef='dc01'}
    }
    $comps=@()
    if($Template -in @('Vault','VaultDR','FullLab')){$comps+=@{id='vault';type='Vault';host='vault01';variant='Standalone'}}
    if($Template -in @('VaultDR','FullLab')){$comps+=@{id='dr';type='DRVault';host='dr01';variant='StandardDR'}}
    if($Template -eq 'FullLab'){
        $comps+=@{id='pvwa';type='PVWA';host='pam01';variant='Standard';options=@{}}
        $comps+=@{id='cpm';type='CPM';host='pam01';variant='Standard';options=@{}}
        $comps+=@{id='psm';type='PSM';host='psm01';variant='Standard';options=@{}}
        $comps+=@{id='psmp';type='PSMP';host='psmp01';variant='Standard';options=@{}}
        $comps+=@{id='pta';type='PTA';host='pta01';variant='Standard';options=@{}}
    }
    if($Template -eq 'ADOnly'){$comps+=@{id='ad';type='AD';host='dc01';variant='NewForest'}}
    if($Template -eq 'ExistingVault'){$comps+=@{id='pvwa';type='PVWA';host='pam01';variant='Standard';options=@{}}}
    $config=[ordered]@{
        schemaVersion=2;name='PASeasyLab';mediaRoot='F:\CyberArk\InstallMedia';controllerAddress='192.0.2.2'
        security=@{profile='Secure';overrides=@{}}
        vault=@{address='192.0.2.11';adminUser='Administrator';secretRef='VaultAdmin';masterSecretRef='VaultMaster';drSecretRef='DRPassword';existing=($Template -eq 'ExistingVault')}
        activeDirectory=@{mode=$(if($Template -eq 'ADOnly'){'Create'}else{'None'});host='dc01';domain='pam.lab';join=@();joinUser='PAM\Administrator';createTestAccounts=$false}
        hosts=$hosts;components=$comps;media=@{};options=@{}
    }
    if($Template -eq 'ADOnly'){$config.vault.existing=$true;$config.activeDirectory.join=@()}
    if($Template -eq 'DomainJoin'){
        $config.vault.existing=$true
        $config.activeDirectory.mode='Existing';$config.activeDirectory.join=@('pam01')
        $config.activeDirectory.dnsServers=@('192.0.2.10')
    }
    if((Test-Path -LiteralPath $Path) -and -not $Force){throw "Configuration exists: $Path (use -Force to overwrite)"}
    if($PSCmdlet.ShouldProcess($Path,'Create sample deployment configuration')){
        Write-PASJsonAtomic -Path $Path -Data $config
    }
    return $config
}
function Test-PASConfiguration {
    [CmdletBinding()]param([string]$Config,$Configuration,[switch]$CheckMedia,[switch]$Strict)
    $c=Read-PASConfiguration -Path $Config -Configuration $Configuration
    $issues=New-Object 'System.Collections.Generic.List[string]'
    $warnings=New-Object 'System.Collections.Generic.List[string]'
    if([int]$c.schemaVersion -ne 2){$issues.Add('schemaVersion must be 2')}
    if([string]$c.name -notmatch '^[A-Za-z0-9_.-]{1,64}$'){$issues.Add('name must be 1-64 safe characters')}
    if($c.hosts -isnot [System.Collections.IDictionary]){$issues.Add('hosts must be an object')}
    $ids=@{}; $windows=@('Vault','DRVault','PVWA','CPM','PSM','AD'); $linux=@('PSMP','PTA')
    if($c.vault -is [System.Collections.IDictionary]){
        foreach($field in @('secretRef','masterSecretRef','drSecretRef')){
            if($c.vault.Contains($field) -and ($c.vault[$field] -isnot [string] -or [string]::IsNullOrWhiteSpace($c.vault[$field]))){$issues.Add("Vault $field must be a nonempty string")}
        }
    }
    foreach($entry in @($c.components)){
        if($null -eq $entry){continue}
        $id=[string]$entry.id; $type=[string]$entry.type; $host=[string]$entry.host
        if($id -notmatch '^[a-z][a-z0-9_-]{0,39}$' -or $ids.ContainsKey($id)){$issues.Add("Invalid or duplicate component id '$id'")}else{$ids[$id]=$true}
        if($type -notin @($windows+$linux)){$issues.Add("Unsupported component type: $type")}
        if(-not $c.hosts -or -not $c.hosts.Contains($host)){$issues.Add("Component $id references unknown host $host");continue}
        $target=$c.hosts[$host]
        if($type -in $windows -and $target.os -ne 'Windows'){$issues.Add("$type requires Windows ($host)")}
        if($type -in $linux -and $target.os -ne 'Linux'){$issues.Add("$type requires Linux ($host)")}
        if($type -in @('Vault','DRVault','AD') -and @($c.components | Where-Object {$_ -and $_.host -eq $host}).Count -gt 1){$issues.Add("$type must have its own dedicated host ($host)")}
        if($type -in @('Vault','DRVault') -and @($c.activeDirectory.join) -contains $host){$issues.Add("Vault host $host must not be domain joined")}
        if($type -eq 'AD' -and $c.activeDirectory.mode -eq 'None'){$issues.Add('AD selected but activeDirectory.mode=None')}
        if($type -eq 'PSM'){$warnings.Add('PSM restricts untrusted creation at the Windows Temp root to protect the native TLS backup; existing child permissions are preserved. Connector compatibility requires functional qualification.')}
        if($type -eq 'PTA' -and (Get-PASValue (Get-PASValue $entry 'options' @{}) 'ptaConfigurationTransport' 'VendorCLI') -notin @('VendorCLI','API')){$issues.Add('PTA configuration transport must be VendorCLI or API')}
        if($type -eq 'PTA' -and (Get-PASValue (Get-PASValue $entry 'options' @{}) 'allowUndersizedMemory' $null) -ne $null){$issues.Add('PTA memory exception must use the audited Lab security override PTA.AllowUndersizedMemory')}
        if($type -eq 'PTA' -and (Get-PASValue (Get-PASValue $entry 'options' @{}) 'allowUndersizedCPU' $null) -ne $null){$issues.Add('PTA CPU exception must use the audited Lab security override PTA.AllowUndersizedCPU')}
        if($type -eq 'PTA'){
            $options=Get-PASValue $entry 'options' @{}
            $ptaIP=$null
            if(-not [Net.IPAddress]::TryParse([string]$target.address,[ref]$ptaIP) -or $ptaIP.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){$issues.Add('PTA TLS requires a literal target IPv4 address; use options.ptaName for its DNS certificate name')}
            $pfx=[string](Get-PASValue $options 'certificatePfxFile' '')
            $pfxHash=[string](Get-PASValue $options 'certificatePfxSHA256' '')
            $name=[string](Get-PASValue $options 'ptaName' '')
            $labCA=($c.security.profile -eq 'Lab' -and [bool](Get-PASValue $c.security.overrides 'PTA.GenerateLabCA' $false))
            if(($pfx -or $pfxHash) -and (-not $pfx -or $pfxHash -notmatch '^[A-Fa-f0-9]{64}$')){$issues.Add('PTA PFX requires options.certificatePfxFile and certificatePfxSHA256')}
            if($pfx -and $labCA){$issues.Add('PTA operator PFX and generated Lab CA are mutually exclusive')}
            if($name -and ($name -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$' -or $name.Contains('..'))){$issues.Add('PTA ptaName must be a safe DNS name')}
            if((Get-PASValue $options 'generateLabCA' $null) -ne $null){$issues.Add('PTA generated CA requires audited Lab security override PTA.GenerateLabCA')}
            if($CheckMedia){
                if(-not $pfx -and -not $labCA){$issues.Add('PTA requires an operator PFX or explicit Lab override PTA.GenerateLabCA')}
                if($pfx){
                    if(-not(Test-Path -LiteralPath $pfx -PathType Leaf)){$issues.Add('PTA PFX file is missing')}
                    elseif((Get-Item -LiteralPath $pfx).Length -le 0 -or (Get-Item -LiteralPath $pfx).Length -gt 32768){$issues.Add('PTA PFX file must contain 1-32768 bytes')}
                }
            }elseif(-not $pfx -and -not $labCA){$warnings.Add('PTA TLS certificate source must be configured before installation')}
        }
        if($type -eq 'CPM'){
            $options=Get-PASValue $entry 'options' @{}
            $trustFile=[string](Get-PASValue $options 'pvwaTrustCertificateFile' '')
            $trustHash=[string](Get-PASValue $options 'pvwaTrustCertificateSHA256' '')
            if(($trustFile -or $trustHash) -and (-not $trustFile -or $trustHash -notmatch '^[A-Fa-f0-9]{64}$')){$issues.Add('CPM public trust certificate requires options.pvwaTrustCertificateFile and pvwaTrustCertificateSHA256')}
            if($CheckMedia -and $trustFile -and -not(Test-Path -LiteralPath $trustFile -PathType Leaf)){$issues.Add('CPM public trust certificate file is missing')}
            if((Get-PASValue $options 'allowPinnedLeafTrust' $null) -ne $null){$issues.Add('CPM leaf trust exception must use audited Lab security override CPM.AllowPinnedLeafTrust')}
        }
        if($type -in @('PSMP','PTA')){$warnings.Add("$type Linux installation requires qualification on the selected target distribution and supplied media")}
        if($CheckMedia -and $type -notin @('Vault','DRVault','AD')){
            $mediaPath=[string](Get-PASValue $entry 'media' '')
            if(-not $mediaPath -or -not(Test-Path -LiteralPath $mediaPath -PathType Leaf)){$issues.Add("Media ZIP missing for component '$id' ($mediaPath)")}
            if($type -eq 'PTA'){
                $opts=Get-PASValue $entry 'options' @{}
                $key=[string](Get-PASValue $opts 'signingKeyFile' '')
                $fingerprint=[string](Get-PASValue $opts 'signingKeyFingerprint' '')
                if(-not $key -or -not(Test-Path -LiteralPath $key -PathType Leaf)){$issues.Add('PTA requires options.signingKeyFile (reviewed vendor public RPM key)')}
                if($fingerprint -notmatch '^[A-Fa-f0-9]{40}$'){$issues.Add('PTA requires reviewed options.signingKeyFingerprint')}
            }
        }
    }
    # A public join-only run has no CyberArk media or Vault authentication dependency.
    # Keep empty deployments invalid unless they explicitly join eligible Windows hosts.
    $joinOnly=$c.activeDirectory.mode -eq 'Existing' -and @($c.activeDirectory.join).Count -gt 0
    if($joinOnly){
        foreach($joinId in @($c.activeDirectory.join)){
            if(-not $c.hosts.Contains([string]$joinId) -or $c.hosts[[string]$joinId].os -ne 'Windows'){$joinOnly=$false}
        }
    }
    if(@($c.components).Count -eq 0 -and -not $joinOnly){$issues.Add('At least one component or an explicit Existing AD Windows domain join is required')}

    if($c.activeDirectory.mode -notin @('None','Create','Existing')){$issues.Add('activeDirectory.mode must be None, Create or Existing')}
    if($c.activeDirectory.mode -eq 'Create' -and @($c.components | Where-Object {$_.type -eq 'AD'}).Count -ne 1){$issues.Add('AD mode Create requires one AD component')}
    if($c.activeDirectory.mode -eq 'Existing' -and @($c.components | Where-Object {$_.type -eq 'AD'}).Count){$issues.Add('AD component is only for creating a new domain')}
    if(@($c.activeDirectory.join).Count -gt 0 -and $c.activeDirectory.mode -ne 'None'){
        foreach($hName in @($c.activeDirectory.join)){
            if(-not $c.hosts.Contains([string]$hName)){$issues.Add("Domain join host does not exist: $hName");continue}
            if($c.hosts[[string]$hName].os -ne 'Windows'){$issues.Add("Linux domain joins are not implemented: $hName")}
            if(@($c.components | Where-Object {$_.host -eq $hName -and $_.type -in @('Vault','DRVault','AD')}).Count){$issues.Add("Vault/DC cannot be joined by deployment: $hName")}
        }
    }
    # Multiple host IDs for one literal endpoint bypass dedicated-role and join guards.
    # Co-location must use one host record so every policy sees the same identity.
    $usedHosts=@(Get-PASDeploymentHostIds $c)
    $reservedCredentialAliases=@()
    if(@($c.components|Where-Object {$_.type -eq 'Vault'}).Count){$reservedCredentialAliases+=@('PrimaryAdmin','DRAdmin')}
    $reservedCredentialAliases+=@($c.components|Where-Object {$_.type -eq 'AD'}|ForEach-Object {([string]$_.id)+'-domain'})
    foreach($entry in @($c.components)){
        if($null -eq $entry){continue}
        if([string]$entry.id -in $usedHosts -and [string]$entry.id -ne [string]$entry.host){$issues.Add("Component '$($entry.id)' collides with a different host's credential key; use distinct IDs")}
        if([string]$entry.id -in $reservedCredentialAliases){$issues.Add("Component '$($entry.id)' collides with a reserved runtime credential alias")}
    }
    foreach($hostId in $usedHosts){
        if($hostId -in $reservedCredentialAliases){$issues.Add("Host '$hostId' collides with a reserved runtime credential alias")}
    }
    $seenAddresses=@{}
    foreach($hostId in $usedHosts){
        if(-not $c.hosts.Contains($hostId)){continue}
        $hostRecord=$c.hosts[$hostId]
        if($hostRecord.Contains('credentialRef') -and ($hostRecord.credentialRef -isnot [string] -or [string]::IsNullOrWhiteSpace($hostRecord.credentialRef))){$issues.Add("Host '$hostId' credentialRef must be a nonempty string")}
        $address=([string]$c.hosts[$hostId].address).TrimEnd('.').ToLowerInvariant()
        $ip=$null
        if([Net.IPAddress]::TryParse($address,[ref]$ip)){if($ip.IsIPv4MappedToIPv6){$ip=$ip.MapToIPv4()};$address=$ip.ToString()}
        if($seenAddresses.ContainsKey($address)){$issues.Add("Host aliases $($seenAddresses[$address]) and $hostId use the same endpoint; use one host record for co-location")}
        else{$seenAddresses[$address]=$hostId}
    }
    $shared=@($c.components|Where-Object{$_.type -in @('PVWA','CPM','PSM')}|Group-Object -Property {[string]$_.host}|Where-Object{$_.Count -gt 1})
    foreach($group in $shared){$warnings.Add("Co-located components on $($group.Name) require lab qualification; vendor Orchestrator does not qualify the combination")}
    if($c.activeDirectory.mode -ne 'None' -and [string]$c.activeDirectory.domain -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]{2,252}$'){$issues.Add('Invalid AD DNS domain name')}
    if($c.activeDirectory.mode -eq 'Create' -and $c.vault.existing -and @($c.components|Where-Object{$_.type -notin @('AD')}).Count -gt 0){$warnings.Add('Existing Vault configured; no new primary Vault will be installed')}
    if($ids.ContainsKey('dr') -and -not $ids.ContainsKey('vault')){$issues.Add('DR requires Primary Vault in the same new deployment')}
    if(@($c.components | Where-Object {$_.type -eq 'DRVault'}).Count -gt 0 -and (@($c.components | Where-Object {$_.type -eq 'Vault'}).Count -ne 1 -or [bool]$c.vault.existing)){$issues.Add('DR may only be installed together with a fresh Primary Vault')}
    if(@($c.components | Where-Object {$_.type -eq 'Vault'}).Count -gt 1){$issues.Add('Only one new primary Vault is qualified in v2')}
    if(@($c.components | Where-Object {$_.type -eq 'DRVault'}).Count -gt 1){$issues.Add('Only one DR Vault is qualified in v2')}
    if($c.security.profile -notin @('Secure','Lab')){$issues.Add('security.profile must be Secure or Lab')}
    if($c.security.profile -eq 'Secure' -and $c.security.overrides -and $c.security.overrides.Count -gt 0){$issues.Add('Security overrides require profile Lab')}
    if($c.security.overrides){
        foreach($name in $c.security.overrides.Keys){
            if($c.security.overrides[$name] -isnot [bool]){$issues.Add("Security override $name must be a JSON boolean")}
            if($name -notin @('PTA.SkipVaultSyslog','PTA.GenerateLabCA','PTA.AllowUndersizedCPU','PTA.AllowUndersizedMemory','Vault.AllowRDP','PVWA.ValidateTLS','CPM.ValidatePVWA','CPM.AllowPinnedLeafTrust','WinRM.RequireHTTPS','WinRM.SkipCACheck','WinRM.SkipCNCheck','PVWA.ApplyHardening','CPM.ApplyHardening','PSM.ApplyHardening','PSMP.ApplyHardening','PTA.ApplyHardening')){
                $issues.Add("Unknown/unsupported lab override '$name'")
            }else{$warnings.Add("SECURITY DEVIATION: $name = $($c.security.overrides[$name])")}
        }
    }
    if(@($c.components|Where-Object {$_.type -eq 'PTA'}).Count){
        $skip=($c.security.profile -eq 'Lab' -and [bool](Get-PASValue $c.security.overrides 'PTA.SkipVaultSyslog' $false))
        $management=Get-PASPTASyslogHost $c
        if(-not $skip -and (-not $management -or -not $c.hosts.Contains($management) -or $c.hosts[$management].os -ne 'Windows')){$issues.Add('PTA TLS syslog requires vault.managementHost referencing the primary Windows host')}
        $endpoint=[string](Get-PASValue $c.vault 'managementEndpoint' 'PAExec.Management')
        if($endpoint -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$'){$issues.Add('Invalid Vault management endpoint name')}
        if(@($c.components|Where-Object {$_.type -eq 'PTA'}).Count -gt 1){$issues.Add('Only one PTA syslog receiver per Vault is supported by this installer')}
        foreach($pta in @($c.components|Where-Object {$_.type -eq 'PTA'})){
            if(@($c.components|Where-Object {$_.id -eq ([string]$pta.id+'-vault-syslog')}).Count){$issues.Add('Component id collides with the reserved PTA Vault syslog continuation')}
        }
    }
    foreach($key in @($c.hosts.Keys)){
        if($key -notmatch '^[a-z][a-z0-9_-]{0,39}$'){$issues.Add("Invalid host id '$key'")}
        $h=$c.hosts[$key]
        if(-not $h.address -or [string]$h.address -match '[\s;`"\x00-\x1f]'){$issues.Add("Unsafe/empty address for $key")}
        if($h.os -notin @('Windows','Linux')){$issues.Add("Invalid OS for $key")}
        if($h.os -eq 'Linux' -and -not $h.user){$issues.Add("SSH user required for $key")}
        if($h.os -eq 'Windows' -and $c.security.profile -eq 'Secure' -and $h.Contains('useSsl') -and -not [bool]$h.useSsl){
            $issues.Add("Secure policy requires WinRM HTTPS on Windows host $key. Use Lab with explicit override to allow HTTP")
        }
    }
    # Do not silently persist conventional secret property names in the config.
    $raw=($c | ConvertTo-Json -Depth 60)
    if($raw -match '"(?:password|vaultAdminPassword|masterPassword|secretValue)"\s*:'){$issues.Add('Configuration appears to contain a plaintext password field: use credential/secret references')}
    if($Strict -and $warnings.Count){foreach($w in $warnings){$issues.Add($w)}}
    return [pscustomobject]@{Valid=($issues.Count -eq 0);Issues=@($issues.ToArray());Warnings=@($warnings.ToArray());Configuration=$c}
}
