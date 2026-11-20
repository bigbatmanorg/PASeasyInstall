[CmdletBinding()]param([Parameter(Mandatory)][hashtable]$Settings)
$ErrorActionPreference = 'Stop'
$name = if ($Settings.ContainsKey('ManagementEndpoint')) { [string]$Settings.ManagementEndpoint }else { 'PASeasyInstall.Management' }
$user = [string]$Settings.ManagementUser
if (-not $user) { throw 'ManagementUser is required for independent endpoint verification' }
if ($user.StartsWith('.\')) { $user = $env:COMPUTERNAME + '\' + $user.Substring(2) }
elseif (-not $user.Contains('\') -and -not $user.Contains('@')) { $user = $env:COMPUTERNAME + '\' + $user }
$sid = ([Security.Principal.NTAccount]::new($user)).Translate([Security.Principal.SecurityIdentifier]).Value
$configuration = Get-PSSessionConfiguration -Name $name -ErrorAction Stop
$descriptor = [Security.AccessControl.RawSecurityDescriptor]::new([string]$configuration.SecurityDescriptorSddl)
$acl = $descriptor.DiscretionaryAcl
$exact = $false
if ($acl -and $acl.Count -eq 1) {
    $ace = $acl[0]
    $exact = ($ace.AceType -eq [Security.AccessControl.AceType]::AccessAllowed -and
        $ace.AceFlags -eq [Security.AccessControl.AceFlags]::None -and
        $ace.AccessMask -eq 268435456 -and
        $ace.SecurityIdentifier.Value -eq $sid)
}
[pscustomobject]@{Passed = ([string]$configuration.Enabled -ieq 'true' -and
        [string]$configuration.RunAsVirtualAccount -ieq 'true' -and
        $exact)
    Message = 'Management endpoint enabled, virtual account selected, and only the configured management SID admitted'
    Evidence = @("Endpoint=$name", "ManagementSID=$sid", "ExactSIDOnlyACL=$exact")
}
