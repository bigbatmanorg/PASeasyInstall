# Build/test tooling only; never imported by the PASeasyInstall runtime.
Set-StrictMode -Version 2
function Test-PASeasyPackageSourcePath {
    param([string]$Path)
    if($Path -notmatch '^PASeasyInstall/[A-Za-z0-9_./-]+$' -or $Path -match '(^|/)\.\.?(/|$)'){return $false}
    if($Path -in @('Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1','Modules/PASeasyInstall.Core/PASeasyInstall.Core.psm1','PASeasyInstall/LICENSE.txt','PASeasyInstall/THIRD_PARTY_EXECUTION_CODE_LICENSE.txt','PASeasyInstall/THIRD_PARTY_VAULT_CODE_LICENSE.txt','PASeasyInstall/Controllers/Invoke-V2Controller.ps1','Modules/PASeasyInstall.Core/Data/LogSources.json')){return $true}
    return ($Path -match '^PASeasyInstall/(Private|UI)/.+\.(ps1|sh)$' -or $Path -match '^PASeasyInstall/Recipes/.+\.(ps1|sh)$' -or $Path -match '^Modules/PASeasyInstall.Vault/Recipes/Vault/Workflows/(?:Verification/)?[A-Za-z0-9_.-]+\.psd1$')
}
function Assert-PASeasyPackageLocalPath {
    param([string]$Path)
    if(-not $Path -or $Path -match '^[A-Za-z]+://' -or $Path.StartsWith('\\')){throw 'Packaging requires a local filesystem path'}
    $full=[IO.Path]::GetFullPath($Path)
    if($full -match '(?:^|[\\/])\.git(?:[\\/]|$)'){throw 'Packaging must not write into Git metadata'}
    if($env:OS -eq 'Windows_NT' -and ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($full))).DriveType -eq [IO.DriveType]::Network){throw 'Mapped network output is not a local package repository'}
    $cursor=$full
    while($cursor){
        $item=Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue
        if($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Packaging refuses symlink/reparse paths'}
        $next=Split-Path $cursor -Parent;if($next -eq $cursor){break};$cursor=$next
    }
    return $full
}
function Get-PASeasyPackageHash {
    param([byte[]]$Bytes,[ValidateSet('SHA256','SHA1')][string]$Algorithm='SHA256')
    $sha=[Security.Cryptography.HashAlgorithm]::Create($Algorithm)
    try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Get-PASeasyPackageSourceDigest {
    param([string]$ModuleRoot)
    # Query the exact frozen implementation in an isolated runspace. Do not
    # assume its digest algorithm or import/unload the caller's runtime module.
    $powershell=[PowerShell]::Create()
    try{
        [void]$powershell.AddScript(@'
param($root)
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $root 'PASeasyInstall.psd1') -Force -PassThru
try{& $module {Get-PASSourceDigest}}finally{Remove-Module $module.Name -Force}
'@).AddArgument($ModuleRoot)
        $result=@($powershell.Invoke())
        if($powershell.HadErrors -or $result.Count -ne 1 -or [string]$result[0] -notmatch '^[a-fA-F0-9]{64}$'){throw 'Frozen module source digest could not be established'}
        return [string]$result[0]
    }finally{$powershell.Dispose()}
}
function Get-PASeasyPackageInventoryDigest {
    param([object[]]$Files)
    [string[]]$entries=@($Files|ForEach-Object {[string]$_.Relative+'='+([string]$_.SHA256).ToLowerInvariant()})
    [Array]::Sort($entries,[StringComparer]::Ordinal)
    Get-PASeasyPackageHash ([Text.Encoding]::UTF8.GetBytes(($entries -join "`n")))
}
function Assert-PASeasyPackageText {
    param([byte[]]$Bytes)
    if($Bytes.Length -gt 2097152 -or $Bytes -contains 0){throw 'Package source is oversized or binary'}
    $text=[Text.Encoding]::UTF8.GetString($Bytes)
    if($text -match '-----BEGIN (?:(?:RSA|EC|OPENSSH|ENCRYPTED) )?PRIVATE KEY-----' -or $text.Contains((-join [char[]](67,121,98,101,114,97,114,107,48,49,33)))){throw 'Package source contains private key material or a lab password literal'}
}
function Write-PASeasyPackageJson {
    param([string]$Path,$Value)
    if(Test-Path -LiteralPath $Path){throw 'Refusing to overwrite package evidence'}
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 15))
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Assert-PASeasyPackageTrustedPath {
    param([string]$Path)
    $cursor=Assert-PASeasyPackageLocalPath $Path
    if(-not(Test-Path -LiteralPath $cursor)){throw 'Package trust boundary must already exist'}
    if($env:OS -eq 'Windows_NT'){
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $trusted=@($sid,'S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        while($cursor){
            $item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Package trust boundary contains a reparse point'}
            $acl=Get-Acl -LiteralPath $cursor -ErrorAction Stop
            if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'Package trust boundary has an untrusted owner'}
            # Directory create-child rights do not modify an existing private child.
            # InheritOnly ACEs do not apply to this existing object. Conservatively
            # reject dangerous grants even where a deny ACE might counteract them.
            [long]$danger=0x10000000L -bor 0x40000000L -bor 0x40000L -bor 0x80000L -bor 0x10000L -bor 0x40L -bor 0x100L -bor 0x10L
            if(-not $item.PSIsContainer){$danger=$danger -bor 2L -bor 4L}
            foreach($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
                if($ace.AccessControlType -ne 'Allow' -or ($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)){continue}
                if($ace.IdentityReference.Value -notin $trusted -and ([long]$ace.FileSystemRights -band $danger)){throw 'Package trust boundary grants untrusted modification or replacement access'}
            }
            $next=Split-Path $cursor -Parent;if($next -eq $cursor){break};$cursor=$next
        }
    }else{
        $uid=[string](& id -u);if($LASTEXITCODE -ne 0 -or $uid -notmatch '^\d+$'){throw 'Cannot establish package builder Unix identity'}
        while($cursor){
            $facts=[string](& stat -c '%u %a' -- $cursor)
            if($LASTEXITCODE -ne 0 -or $facts -notmatch '^(\d+) ([0-7]{3,4})$'){throw 'Cannot establish Unix package boundary ownership/mode'}
            $owner=$Matches[1];$mode=[Convert]::ToInt32($Matches[2],8)
            if($owner -notin @('0',$uid)){throw 'Package trust boundary has an untrusted Unix owner'}
            # Root-owned sticky ancestors (e.g. /tmp) prevent another UID from
            # replacing our atomically-created owned private child.
            if(($mode -band 18) -and -not($owner -eq '0' -and ($mode -band 512))){throw 'Package trust boundary has a writable Unix ancestor without root sticky protection'}
            $next=Split-Path $cursor -Parent;if($next -eq $cursor){break};$cursor=$next
        }
    }
}
function New-PASeasyPackagePrivateOutput {
    param([string]$Path)
    $full=Assert-PASeasyPackageLocalPath $Path
    if(Test-Path -LiteralPath $full){throw 'Output directory already exists; preserve prior artifacts and choose a new path'}
    $parent=Split-Path $full -Parent
    if(-not(Test-Path -LiteralPath $parent -PathType Container)){throw 'Package output parent must already exist'}
    Assert-PASeasyPackageTrustedPath $parent
    if($env:OS -eq 'Windows_NT'){
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=[Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false)
        foreach($identity in @($sid.Value,'S-1-5-18','S-1-5-32-544')){
            $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($identity),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
            $acl.AddAccessRule($rule)
        }
        # CreateDirectory's security-descriptor overload applies the private DACL
        # at creation, before archive/source bytes are written.
        if(-not ('PASeasyPackage.NativeDirectory' -as [type])){
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace PASeasyPackage {
 public static class NativeDirectory {
  [StructLayout(LayoutKind.Sequential)] public struct SecurityAttributes { public int Length; public IntPtr Descriptor; public int Inherit; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool CreateDirectory(string path, ref SecurityAttributes attributes);
 }
}
'@
        }
        $descriptor=$acl.GetSecurityDescriptorBinaryForm()
        $buffer=[Runtime.InteropServices.Marshal]::AllocHGlobal($descriptor.Length)
        try{
            [Runtime.InteropServices.Marshal]::Copy($descriptor,0,$buffer,$descriptor.Length)
            $attributes=New-Object PASeasyPackage.NativeDirectory+SecurityAttributes
            $attributes.Length=[Runtime.InteropServices.Marshal]::SizeOf($attributes)
            $attributes.Descriptor=$buffer
            if(-not [PASeasyPackage.NativeDirectory]::CreateDirectory($full,[ref]$attributes)){throw 'Cannot exclusively create new private package output (existing path or filesystem failure)'}
        }finally{[Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)}
        $observed=Get-Acl -LiteralPath $full
        if(-not $observed.AreAccessRulesProtected -or $observed.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value){throw 'New package output lacks its private protected owner/DACL'}
        $allowed=@($sid.Value,'S-1-5-18','S-1-5-32-544')
        foreach($ace in $observed.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
            if($ace.AccessControlType -ne 'Allow' -or $ace.IdentityReference.Value -notin $allowed){throw 'New package output has an unexpected ACL entry'}
        }
    }else{
        # GNU mkdir creates with 0700 atomically and refuses an existing path.
        & mkdir --mode=700 -- $full
        if($LASTEXITCODE -ne 0){throw 'Cannot create new private Unix package output'}
        $uid=[string](& id -u)
        $facts=[string](& stat -c '%u %a' -- $full)
        if($LASTEXITCODE -ne 0 -or $facts -cne ($uid+' 700')){throw 'New Unix package output must be owned by the builder with mode0700'}
    }
    Assert-PASeasyPackageTrustedPath $full
    if(@(Get-ChildItem -LiteralPath $full -Force).Count){throw 'New package output was not empty'}
    return $full
}
function Assert-PASeasyPackageStagedFiles {
    param([string]$ModuleRoot,[object[]]$Files)
    Assert-PASeasyPackageTrustedPath $ModuleRoot
    $actual=@(Get-ChildItem -LiteralPath $ModuleRoot -Recurse -Force -File)
    if($actual.Count -ne $Files.Count){throw 'Staged package file count changed before import'}
    foreach($file in $Files){
        $path=Join-Path $ModuleRoot $file.Relative
        Assert-PASeasyPackageTrustedPath $path
        $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if($item.PSIsContainer -or $item.Length -ne $file.Bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $file.SHA256){throw 'Staged package bytes changed before import'}
    }
}
