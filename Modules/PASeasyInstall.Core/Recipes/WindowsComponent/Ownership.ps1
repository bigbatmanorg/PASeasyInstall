# Enables only an EXISTING token privilege for a bounded, already-validated filesystem operation.
# This neither grants account rights nor changes machine policy. Callers validate their boundary first.
if(-not ('PASeasyInstall.Native.RestorePrivilegeScopeV1' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace PASeasyInstall.Native {
 public sealed class RestorePrivilegeScopeV1 : IDisposable {
  [StructLayout(LayoutKind.Sequential)] struct Luid { public uint Low; public int High; }
  [StructLayout(LayoutKind.Sequential)] struct Privileges { public uint Count; public Luid Id; public uint Attributes; }
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentThread();
  [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern void SetLastError(uint value);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenThreadToken(IntPtr t,uint access,bool self,out IntPtr h);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool OpenProcessToken(IntPtr p,uint access,out IntPtr h);
  [DllImport("advapi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool LookupPrivilegeValue(string system,string name,out Luid id);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool AdjustTokenPrivileges(IntPtr h,bool disable,ref Privileges state,uint size,out Privileges previous,out uint length);
  [DllImport("advapi32.dll",EntryPoint="AdjustTokenPrivileges",SetLastError=true)] static extern bool RestoreTokenPrivileges(IntPtr h,bool disable,ref Privileges state,uint size,IntPtr previous,IntPtr length);
  [DllImport("advapi32.dll",SetLastError=true)] static extern bool GetTokenInformation(IntPtr h,int kind,IntPtr buffer,uint size,out uint required);
  IntPtr token; Privileges prior;
  static IntPtr Open(uint access) {
   IntPtr h;
   if(OpenThreadToken(GetCurrentThread(),access,true,out h)) return h;
   int error=Marshal.GetLastWin32Error();
   if(error!=1008) throw new Win32Exception(error,"Cannot open current thread token");
   if(!OpenProcessToken(GetCurrentProcess(),access,out h)) throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot open current process token");
   return h;
  }
  static Luid Id() { Luid id;if(!LookupPrivilegeValue(null,"SeRestorePrivilege",out id))throw new Win32Exception(Marshal.GetLastWin32Error());return id; }
  public static int Attributes() {
   IntPtr h=Open(8),buffer=IntPtr.Zero;
   try {
    uint required;GetTokenInformation(h,3,IntPtr.Zero,0,out required);
    if(required==0)throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot size token privileges");
    buffer=Marshal.AllocHGlobal((int)required);
    if(!GetTokenInformation(h,3,buffer,required,out required))throw new Win32Exception(Marshal.GetLastWin32Error(),"Cannot read token privileges");
    int count=Marshal.ReadInt32(buffer);Luid wanted=Id();
    for(int i=0;i<count;i++) {IntPtr p=IntPtr.Add(buffer,4+i*12);if(unchecked((uint)Marshal.ReadInt32(p))==wanted.Low && Marshal.ReadInt32(p,4)==wanted.High)return Marshal.ReadInt32(p,8);}
    return -1;
   } finally {if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer);CloseHandle(h);}
  }
  public static RestorePrivilegeScopeV1 Enable() {
   var scope=new RestorePrivilegeScopeV1();scope.token=Open(40);
   try {
    var requested=new Privileges {Count=1,Id=Id(),Attributes=2};uint length;
    SetLastError(0);
    bool ok=AdjustTokenPrivileges(scope.token,false,ref requested,(uint)Marshal.SizeOf(typeof(Privileges)),out scope.prior,out length);
    int error=Marshal.GetLastWin32Error();
    if(!ok || error!=0)throw new Win32Exception(error,"Existing SeRestorePrivilege could not be enabled");
    return scope;
   } catch {scope.Dispose();throw;}
  }
  public void Dispose() {
   IntPtr h=token;if(h==IntPtr.Zero)return;token=IntPtr.Zero;
   try {
    if(prior.Count!=0) {SetLastError(0);bool ok=RestoreTokenPrivileges(h,false,ref prior,0,IntPtr.Zero,IntPtr.Zero);int error=Marshal.GetLastWin32Error();if(!ok || error!=0)throw new Win32Exception(error,"SeRestorePrivilege state could not be restored");}
   } finally {CloseHandle(h);}
  }
 }
}
'@
}
function Get-PASeasyRestorePrivilegeState {
    $attributes=[PASeasyInstall.Native.RestorePrivilegeScopeV1]::Attributes()
    [pscustomobject]@{Present=($attributes -ge 0);Enabled=($attributes -ge 0 -and ($attributes -band 2) -ne 0);Attributes=$attributes}
}
function Invoke-PASeasyWithRestorePrivilege {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Action)
    $scope=[PASeasyInstall.Native.RestorePrivilegeScopeV1]::Enable()
    try {& $Action}finally{$scope.Dispose()}
}
