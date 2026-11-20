# Which credentials and secrets a configuration needs, and how missing ones are prompted for.
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

