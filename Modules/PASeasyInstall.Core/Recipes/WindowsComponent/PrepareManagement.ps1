# Runs elevated/detached before vendor work; grants only the explicitly configured identity.
[CmdletBinding()]
param([Parameter(Mandatory)][hashtable]$Settings)
$ErrorActionPreference='Stop'
function Get-PASeasyManagementAccountName {
    param([Parameter(Mandatory)][string]$User)
    if(-not $User -or $User -ne $User.Trim()){throw 'ManagementUser must be an explicit nonempty account name'}
    if($User.StartsWith('.\')){return ($env:COMPUTERNAME+'\'+$User.Substring(2))}
    if($User.Contains('\') -or $User.Contains('@')){return $User}
    return ($env:COMPUTERNAME+'\'+$User)
}
function Test-PASeasyManagementEndpoint {
    param($Configuration,[Parameter(Mandatory)][string]$Sid)
    if(-not $Configuration -or [string]$Configuration.Enabled -ine 'true' -or [string]$Configuration.RunAsVirtualAccount -ine 'true'){return $false}
    try {
        $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new([string]$Configuration.SecurityDescriptorSddl)
        $acl=$descriptor.DiscretionaryAcl
        if(-not $acl -or $acl.Count -ne 1){return $false}
        $ace=$acl[0]
        return ($ace.AceType -eq [Security.AccessControl.AceType]::AccessAllowed -and $ace.AceFlags -eq [Security.AccessControl.AceFlags]::None -and $ace.AccessMask -eq 268435456 -and $ace.SecurityIdentifier.Value -eq $Sid)
    }catch{return $false}
}
function Invoke-PASeasyManagementPreparation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Settings)
    $me=[Security.Principal.WindowsIdentity]::GetCurrent()
    if(-not([Security.Principal.WindowsPrincipal]::new($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Management endpoint preparation requires an elevated administrator or SYSTEM'}
    $user=Get-PASeasyManagementAccountName -User ([string]$Settings.ManagementUser)
    $sid=([Security.Principal.NTAccount]::new($user)).Translate([Security.Principal.SecurityIdentifier]).Value
    $name='PASeasyInstall.Management'
    if($Settings.ContainsKey('ManagementEndpoint') -and $Settings.ManagementEndpoint){$name=[string]$Settings.ManagementEndpoint}
    if($name -notmatch '^[A-Za-z][A-Za-z0-9.]{0,63}$'){throw 'Invalid management endpoint name'}
    $existing=Get-PSSessionConfiguration -Name $name -ErrorAction SilentlyContinue
    if($existing){
        if(-not(Test-PASeasyManagementEndpoint -Configuration $existing -Sid $sid)){throw 'Existing management endpoint differs from the requested restricted identity/configuration; elevated reconciliation is required'}
        return [pscustomobject]@{Changed=$false;Message="Restricted management endpoint $name already verified for $sid"}
    }
    $base=Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'PASeasyInstall'
    $store=Join-Path $base 'management'
    $file=Join-Path $store ($name+'.pssc')
    $trusted=@('S-1-5-18','S-1-5-32-544',$me.User.Value,$sid,'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $ancestor=$file
    while($ancestor){
        if(Test-Path -LiteralPath $ancestor){
            $item=Get-Item -LiteralPath $ancestor -Force
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Management staging has a reparse ancestor'}
            if((Get-Acl -LiteralPath $ancestor).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'Management staging has an untrusted owner'}
        }
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)
    }
    foreach($directory in @($base,$store)){
        if(-not(Test-Path -LiteralPath $directory)){New-Item -ItemType Directory -Path $directory -ErrorAction Stop|Out-Null}
        $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
        foreach($identitySid in @('S-1-5-18','S-1-5-32-544')){
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($identitySid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        }
        ([IO.DirectoryInfo]::new($directory)).SetAccessControl($acl)
    }
    if(Test-Path -LiteralPath $file){
        # Interrupted preparation can reuse only its exact safe data-only definition.
        $definition=Import-PowerShellDataFile -LiteralPath $file -ErrorAction Stop
        $allowed=@('SchemaVersion','GUID','Author','CompanyName','Copyright','Description','SessionType','ExecutionPolicy','RunAsVirtualAccount')
        if(@($definition.Keys|Where-Object {$_ -notin $allowed}).Count -or $definition.SessionType -ne 'Default' -or $definition.ExecutionPolicy -ne 'RemoteSigned' -or $definition.RunAsVirtualAccount -ne $true -or $definition.Description -ne 'PASeasyInstall restricted management endpoint'){throw 'Existing management definition requires elevated reconciliation'}
        $fileAcl=Get-Acl -LiteralPath $file
        foreach($rule in $fileAcl.Access){
            if($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]'Write,Delete,ChangePermissions,TakeOwnership') -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'Existing management definition permits an untrusted writer'}
        }
    }else{
        New-PSSessionConfigurationFile -Path $file -SessionType Default -RunAsVirtualAccount -ExecutionPolicy RemoteSigned -Description 'PASeasyInstall restricted management endpoint'
    }
    $sddl="O:NSG:BAD:P(A;;GA;;;$sid)S:P(AU;FA;GA;;;WD)(AU;SA;GXGW;;;WD)"
    Register-PSSessionConfiguration -Name $name -Path $file -SecurityDescriptorSddl $sddl -Force -NoServiceRestart|Out-Null
    Restart-Service WinRM -Force
    (Get-Service WinRM).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(30))
    $registered=Get-PSSessionConfiguration -Name $name -ErrorAction Stop
    if(-not(Test-PASeasyManagementEndpoint -Configuration $registered -Sid $sid)){throw 'New restricted management endpoint did not verify'}
    return [pscustomobject]@{Changed=$true;Message="Restricted management endpoint $name verified for $sid; virtual administrator sessions enabled"}
}
if($MyInvocation.InvocationName -ne '.') {Invoke-PASeasyManagementPreparation -Settings $Settings}
