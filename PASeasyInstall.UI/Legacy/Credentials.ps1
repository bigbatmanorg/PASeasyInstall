# Private UI credential memory. No credential/password is bound to NativeHTMLKit markup,
# configuration JSON, diagnostics, or a process command line.
function New-PASeasyUICredentialCache {
    return @{Credentials=@{};Secrets=@{};SharedLabPassword=$null}
}
function Clear-PASeasyUICredentials {
    param($State)
    $State.Auth=New-PASeasyUICredentialCache
}
function Get-PASeasyUIPrincipalRefs {
    param($Configuration)
    $refs=@{}
    foreach($component in @($Configuration.components|Where-Object {$_.type -eq 'PSM'})){
        $ref='';$options=$component.PSObject.Properties['options']
        if($options -and $options.Value -and $options.Value.PSObject.Properties['taskPrincipalCredentialRef']){$ref=[string]$options.Value.taskPrincipalCredentialRef}
        elseif($Configuration.activeDirectory.mode -ne 'None' -and @($Configuration.activeDirectory.join) -contains [string]$component.host){$ref='PSMDomainInstaller'}
        if($ref){$refs[$ref]=[string]$Configuration.activeDirectory.joinUser}
    }
    return $refs
}
function New-PASeasyUICredentials {
    param($S,[string]$Path,[switch]$HostOnly)
    $c=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $selected=@(@($c.components|ForEach-Object {[string]$_.host})+@($c.activeDirectory.join)|Sort-Object -Unique)
    if(-not $HostOnly -and @($c.components|Where-Object {$_.type -eq 'PTA'}).Count){
        $assessment=Test-PASeasyConfig -Config $Path
        if(-not $assessment.Valid){throw ($assessment.Issues -join '; ')}
        $managementHost=& (Get-Module PASeasyInstall.Core) {param($config) Get-PASeasyPTASyslogHost $config} $assessment.Configuration
        if($managementHost){$selected=@($selected+@($managementHost)|Sort-Object -Unique)}
    }
    $creds=@{};$secrets=@{}
    $shared=$S.Auth.SharedLabPassword
    if($shared -and $c.security.profile -ne 'Lab'){throw 'Shared lab credential shortcut requires an explicitly saved Lab profile'}
    foreach($id in $selected){
        $h=$c.hosts.PSObject.Properties[$id]
        if(-not $h){throw "Selected credential host is absent: $id"}
        if($h.Value.os -ne 'Windows'){continue}
        if($S.Auth.Credentials.ContainsKey($id)){$creds[$id]=$S.Auth.Credentials[$id]}
        elseif($shared){$creds[$id]=[pscredential]::new([string]$h.Value.user,$shared)}
        else{throw "Supply Windows credentials for selected host '$id'"}
    }
    if($HostOnly){return @{Credentials=$creds;Secrets=@{}}}
    $principals=Get-PASeasyUIPrincipalRefs $c
    foreach($ref in $principals.Keys){
        if($S.Auth.Credentials.ContainsKey($ref)){$creds[$ref]=$S.Auth.Credentials[$ref]}
        elseif($shared -and $principals[$ref]){$creds[$ref]=[pscredential]::new($principals[$ref],$shared)}
        else{throw "Supply installer identity for credential reference '$ref'"}
    }
    $types=@($c.components|ForEach-Object {[string]$_.type})
    $required=@()
    if(@($types|Where-Object {$_ -ne 'AD'}).Count){$required+='VaultAdmin'}
    if($types -contains 'Vault'){$required+='VaultMaster'}
    if($types -contains 'DRVault'){$required+='DRPassword'}
    if($types -contains 'AD'){$required+='ADSafeMode'}
    $ptaAPI=@($c.components|Where-Object {$_.type -eq 'PTA' -and $_.PSObject.Properties['options'] -and $_.options -and $_.options.PSObject.Properties['ptaConfigurationTransport'] -and $_.options.ptaConfigurationTransport -eq 'API'})
    if($ptaAPI.Count){$required+='PTAInstallerPassword'}
    $ptaPFX=@($c.components|Where-Object {$_.type -eq 'PTA' -and $_.PSObject.Properties['options'] -and $_.options -and $_.options.PSObject.Properties['certificatePfxFile'] -and $_.options.certificatePfxFile})
    if($ptaPFX.Count){$required+='PTACertificatePassword'}
    if(@($c.activeDirectory.join).Count){$required+='DomainJoinPassword'}
    foreach($role in $required){
        if($S.Auth.Secrets.ContainsKey($role)){$secrets[$role]=$S.Auth.Secrets[$role]}
        elseif($shared){$secrets[$role]=$shared}
        else{throw "Supply password for role '$role'"}
    }
    return @{Credentials=$creds;Secrets=$secrets}
}

function Initialize-PASeasyNativeCredentialPrompt {
    if('PASeasyInstall.NativeCredentialPrompt' -as [type]){return}
    # Public Win32 Credential UI with DO_NOT_PERSIST; no Credential Manager writes.
    # https://learn.microsoft.com/windows/win32/api/wincred/nf-wincred-creduipromptforcredentialsw
    Add-Type -TypeDefinition @'
using System;
using System.Security;
using System.Runtime.InteropServices;
using System.ComponentModel;
namespace PASeasyInstall {
 public sealed class PromptCredential { public string UserName; public SecureString Password; }
 public static class NativeCredentialPrompt {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  private struct Info { public int Size; public IntPtr Parent; public string Message; public string Caption; public IntPtr Banner; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
  private static extern IntPtr FindWindowW(string className, string windowName);
  [DllImport("credui.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
  private static extern int CredUIPromptForCredentialsW(ref Info info, string target, IntPtr reserved, int error, IntPtr user, int userSize, IntPtr password, int passwordSize, ref bool save, int flags);
  private static void Erase(IntPtr buffer, int count) { if(buffer==IntPtr.Zero)return; for(int i=0;i<count;i++)Marshal.WriteByte(buffer,i,0); Marshal.FreeHGlobal(buffer); }
  public static PromptCredential Prompt(string initialUser, string message) {
   const int capacity=513; const int bytes=capacity*2;
   if(initialUser==null)initialUser="";
   if(initialUser.Length>=capacity)throw new ArgumentException("Credential username is too long");
   IntPtr user=IntPtr.Zero,password=IntPtr.Zero;
   SecureString secure=null;
   try {
    user=Marshal.AllocHGlobal(bytes);password=Marshal.AllocHGlobal(bytes);
    for(int i=0;i<bytes;i++){Marshal.WriteByte(user,i,0);Marshal.WriteByte(password,i,0);}
    byte[] seed=System.Text.Encoding.Unicode.GetBytes(initialUser+"\0");Marshal.Copy(seed,0,user,seed.Length);
    Info info=new Info();info.Size=Marshal.SizeOf(typeof(Info));info.Parent=FindWindowW(null,"PASeasyInstall");info.Message=message;info.Caption="PASeasyInstall credentials";
    bool save=false;
    int status=CredUIPromptForCredentialsW(ref info,"PASeasyInstall",IntPtr.Zero,0,user,capacity,password,capacity,ref save,0x40082);
    if(status==1223)return null;
    if(status!=0)throw new Win32Exception(status);
    secure=new SecureString();
    for(int i=0;i<capacity;i++){char ch=(char)Marshal.ReadInt16(password,i*2);if(ch=='\0')break;secure.AppendChar(ch);}
    secure.MakeReadOnly();
    PromptCredential result=new PromptCredential();result.UserName=Marshal.PtrToStringUni(user);result.Password=secure;secure=null;
    return result;
   } finally {if(secure!=null)secure.Dispose();Erase(password,bytes);Erase(user,bytes);}
  }
 }
}
'@
}
function Request-PASeasyUICredential {
    [CmdletBinding()]param([string]$UserName,[string]$Message)
    if($env:OS -ne 'Windows_NT'){throw 'Native credential dialog requires Windows'}
    Initialize-PASeasyNativeCredentialPrompt
    $result=[PASeasyInstall.NativeCredentialPrompt]::Prompt($UserName,$Message)
    if($null -eq $result){return $null}
    return [pscredential]::new($result.UserName,$result.Password)
}

# Presentation-only discovery of required prompts. The existing credential resolver
# remains the single enforcement point when Start/Resume is actually requested.
function Get-PASeasyUIInputRequirements {
    param([Parameter(Mandatory)][string]$Path)
    $c=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    $selected=@(@($c.components|ForEach-Object {[string]$_.host})+@($c.activeDirectory.join)|Where-Object {$_}|Sort-Object -Unique)
    if(@($c.components|Where-Object {$_.type -eq 'PTA'}).Count){
        $assessment=Test-PASeasyConfig -Config $Path
        if(-not $assessment.Valid){throw ($assessment.Issues -join '; ')}
        $managementHost=& (Get-Module PASeasyInstall.Core) {param($config) Get-PASeasyPTASyslogHost $config} $assessment.Configuration
        if($managementHost){$selected=@($selected+@($managementHost)|Sort-Object -Unique)}
    }
    $windows=@(foreach($id in $selected){
        $hostProperty=$c.hosts.PSObject.Properties[[string]$id]
        if(-not $hostProperty){throw "Unknown target host '$id'"}
        if([string]$hostProperty.Value.os -eq 'Windows'){
            [pscustomobject]@{Id=[string]$id;User=[string]$hostProperty.Value.user}
        }
    })
    $principals=Get-PASeasyUIPrincipalRefs $c
    $types=@($c.components|ForEach-Object {[string]$_.type})
    $roles=@()
    if(@($types|Where-Object {$_ -ne 'AD'}).Count){$roles+='VaultAdmin'}
    if($types -contains 'Vault'){$roles+='VaultMaster'}
    if($types -contains 'DRVault'){$roles+='DRPassword'}
    if($types -contains 'AD'){$roles+='ADSafeMode'}
    if(@($c.components|Where-Object {$_.type -eq 'PTA' -and $_.options.ptaConfigurationTransport -eq 'API'}).Count){$roles+='PTAInstallerPassword'}
    if(@($c.components|Where-Object {$_.type -eq 'PTA' -and $_.options.certificatePfxFile}).Count){$roles+='PTACertificatePassword'}
    if(@($c.activeDirectory.join).Count){$roles+='DomainJoinPassword'}
    return @{WindowsHosts=$windows;PrincipalRefs=$principals;Roles=@($roles)}
}
function Request-PASeasyUIRequiredCredentials {
    param($State,[string]$Path)
    $r=Get-PASeasyUIInputRequirements -Path $Path
    foreach($host in @($r.WindowsHosts)){
        if($State.Auth.Credentials.ContainsKey($host.Id)){continue}
        $credential=Request-PASeasyUICredential -UserName $host.User -Message ("Windows administrator for $($host.Id)")
        if(-not $credential){throw "Credential collection canceled for $($host.Id); no installation was started"}
        $State.Auth.Credentials[$host.Id]=$credential
    }
    foreach($reference in @($r.PrincipalRefs.Keys|Sort-Object)){
        if($State.Auth.Credentials.ContainsKey($reference)){continue}
        $credential=Request-PASeasyUICredential -UserName $r.PrincipalRefs[$reference] -Message ("Installer identity $reference")
        if(-not $credential){throw "Credential collection canceled for $reference; no installation was started"}
        $State.Auth.Credentials[$reference]=$credential
    }
    foreach($role in @($r.Roles)){
        if($State.Auth.Secrets.ContainsKey($role)){continue}
        $credential=Request-PASeasyUICredential -UserName $role -Message ("Password for $role (username is a role label)")
        if(-not $credential){throw "Credential collection canceled for $role; no installation was started"}
        $State.Auth.Secrets[$role]=$credential.Password
    }
    return $r
}
