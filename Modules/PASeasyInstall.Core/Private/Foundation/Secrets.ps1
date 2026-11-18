# DPAPI handoff for a same-user Windows PowerShell 5.1 controller process.
# NEVER persist cleartext passwords, and never put passwords in command line arguments.
function Assert-PASWindowsIdentity {
    if ($env:OS -ne 'Windows_NT') { throw 'Credential handoff requires Windows DPAPI and the same Windows logon account' }
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Protect-PASDirectory {
    param([string]$Path)
    $sid=Assert-PASWindowsIdentity
    $full=[IO.Path]::GetFullPath($Path)
    if($full.TrimEnd('\') -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')){throw 'Refusing to protect a volume root'}
    $trustedOwners=@($sid,'S-1-5-18','S-1-5-32-544')
    try{$trustedOwners+=([Security.Principal.NTAccount]::new('NT SERVICE','TrustedInstaller')).Translate([Security.Principal.SecurityIdentifier]).Value}catch{}
    $ancestor=$full
    while($ancestor){
        if(Test-Path -LiteralPath $ancestor){
            if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Protected directory has a reparse ancestor'}
            if((Get-Acl -LiteralPath $ancestor).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trustedOwners){throw 'Protected directory has an untrusted ancestor owner'}
        }
        $next=Split-Path -Parent $ancestor;if($next -eq $ancestor){break};$ancestor=$next
    }
    if (-not(Test-Path -LiteralPath $full)){New-Item -ItemType Directory -Path $full -ErrorAction Stop | Out-Null}
    $acl=Get-Acl -LiteralPath $full
    $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if($owner -notin @($sid,'S-1-5-18','S-1-5-32-544')){throw 'Protected directory has an untrusted owner'}
    # A fresh descriptor marks only DACL changes. PowerShell Set-Acl can otherwise
    # try to persist SACL/owner sections and require SeSecurityPrivilege on repeat calls.
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach($identity in @($sid,'S-1-5-18')){
        $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($identity),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    ([IO.DirectoryInfo]::new($full)).SetAccessControl($acl)
}
