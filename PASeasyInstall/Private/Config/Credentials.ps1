# Which credentials and secrets a configuration needs, and how missing ones are prompted for.
function Get-PASInstallRequirement {
    <# What a configuration needs before it can run: one credential per server and the Vault/AD secrets.
       One object per requirement: Kind (Credential or Secret), Key (the CredentialMap / SecretMap key),
       HostId, User, Os, Label. Public face: Get-PASCredentialRequirement. #>
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

function Assert-PASLabPassword {
    # -LabPassword means "one password for every server and every secret". Only the Lab profile allows it.
    param($Configuration, [securestring]$LabPassword)
    if ($LabPassword -and [string]$Configuration.security.profile -ne 'Lab') {
        throw '-LabPassword (one password for everything) is only allowed with the Lab security profile. Add -SecurityProfile Lab (or set security.profile to Lab in the configuration), or pass the credentials separately.'
    }
}

function Resolve-PASInstallCredential {
    # Completes the credentials and secrets a configuration needs (see Get-PASInstallRequirement).
    # What the caller supplied is kept. What is missing is taken from -LabPassword, or asked for
    # interactively: Get-Credential for a server account, Read-Host -AsSecureString for a secret.
    # Returns @{ Credentials = @{ key = PSCredential }; Secrets = @{ key = SecureString } }.
    #
    # User names are returned as entered. The '.\Administrator' form WinRM needs for a workgroup server
    # is applied in one place only: ConvertTo-PASControllerCredentialMap, when a run is started,
    # resumed or stopped.
    param(
        $Configuration,
        [hashtable]$CredentialMap,
        [hashtable]$SecretMap,
        [securestring]$LabPassword
    )
    Assert-PASLabPassword $Configuration $LabPassword

    # Work on copies: the caller's hashtables are never changed.
    $credentials = @{}
    if ($CredentialMap) {
        foreach ($key in $CredentialMap.Keys) {
            $credentials[$key] = $CredentialMap[$key]
        }
    }
    $secrets = @{}
    if ($SecretMap) {
        foreach ($key in $SecretMap.Keys) {
            $secrets[$key] = $SecretMap[$key]
        }
    }

    foreach ($requirement in @(Get-PASInstallRequirement $Configuration)) {
        if ($requirement.Kind -eq 'Credential') {
            # A server credential may be filed under its credentialRef or under the host id.
            $known = $credentials.ContainsKey($requirement.Key)
            if (-not $known -and $requirement.HostId) {
                $known = $credentials.ContainsKey($requirement.HostId)
            }
            if ($known) {
                continue
            }
            if ($LabPassword) {
                $credential = [pscredential]::new($requirement.User, $LabPassword.Copy())
            } else {
                $credential = Get-Credential -UserName $requirement.User -Message ('PASeasyInstall: ' + $requirement.Label)
                if (-not $credential) {
                    throw "Cancelled: no credential was given for $($requirement.Label). Run the command again, or pass it with -Credential / -CredentialMap."
                }
            }
            $credentials[$requirement.Key] = $credential
            if ($requirement.HostId -and $requirement.HostId -ne $requirement.Key) {
                $credentials[$requirement.HostId] = $credential
            }
        } else {
            if ($secrets.ContainsKey($requirement.Key)) {
                continue
            }
            if ($LabPassword) {
                $secret = $LabPassword.Copy()
            } else {
                $secret = Read-Host -AsSecureString -Prompt ('PASeasyInstall: ' + $requirement.Label)
            }
            if (-not $secret -or $secret.Length -eq 0) {
                throw "Empty secret: $($requirement.Label). Run the command again and enter a value, or pass it with -SecretMap @{ $($requirement.Key) = <SecureString> }."
            }
            $secrets[$requirement.Key] = $secret
        }
    }
    return @{ Credentials = $credentials; Secrets = $secrets }
}
