# Controller-wide coordination is deliberately independent of a user's DataRoot.
function Get-PASeasyCoordinationRoot {
    if($env:OS -ne 'Windows_NT'){throw 'Deployment coordination requires a Windows controller'}
    Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'PASeasyInstall-Coordination'
}
function New-PASeasyCoordinationAcl {
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    # Operators can create their own journals, but cannot delete or modify another
    # operator's journal. This is a local controller boundary, not a distributed lock.
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-11'),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-11'),'CreateFiles','None','None','Allow'))
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-3-0'),'FullControl','ObjectInherit','InheritOnly','Allow'))
    return $acl
}
function Initialize-PASeasyController {
    [CmdletBinding()]param()
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if(-not([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run Initialize-PASeasyController once from an elevated Windows PowerShell session'}
    $root=Get-PASeasyCoordinationRoot
    if(Test-Path -LiteralPath $root){
        $item=Get-Item -LiteralPath $root -Force
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Coordination root is a reparse point'}
        if((Get-Acl $root).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544',$identity.User.Value)){throw 'Coordination root has an untrusted owner'}
    }else{[void][IO.Directory]::CreateDirectory($root)}
    $acl=New-PASeasyCoordinationAcl
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    ([IO.DirectoryInfo]::new($root)).SetAccessControl($acl)
    [pscustomobject]@{CoordinationRoot=$root;Initialized=$true}
}
function Assert-PASeasyCoordinationRoot {
    $root=Get-PASeasyCoordinationRoot
    if(-not(Test-Path -LiteralPath $root)){$null=Initialize-PASeasyController}
    $item=Get-Item -LiteralPath $root -Force
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Coordination root is a reparse point'}
    $acl=Get-Acl -LiteralPath $root
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544')){throw 'Coordination root has an untrusted owner'}
    $section=[Security.AccessControl.AccessControlSections]::Access
    if(($acl.GetSecurityDescriptorSddlForm($section) -replace '^D:PAI','D:P') -ne (New-PASeasyCoordinationAcl).GetSecurityDescriptorSddlForm($section)){throw 'Coordination ACL differs from the initialized controller policy'}
    return $root
}
function Get-PASeasyResourceIdentity {
    param([string]$Address)
    $ip=$null
    if([Net.IPAddress]::TryParse($Address,[ref]$ip)){if($ip.IsIPv4MappedToIPv6){$ip=$ip.MapToIPv4()};return $ip.ToString().ToLowerInvariant()}
    $addresses=@([Net.Dns]::GetHostAddresses($Address.TrimEnd('.')) | ForEach-Object {$_.ToString().ToLowerInvariant()} | Sort-Object -Unique)
    if(-not $addresses.Count){throw 'Cannot resolve resource identity for coordination'}
    # Lock each resolved address at the caller; do not hash an entire DNS answer set.
    return $addresses
}
function Enter-PASeasyVaultOperation {
    param([Parameter(Mandatory)][string]$Address,[Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$RunId,[int]$TimeoutSeconds=180)
    $gates=New-Object System.Collections.ArrayList
    try{
        foreach($identity in @(Get-PASeasyResourceIdentity $Address|Sort-Object -Unique)){
            [void]$gates.Add((Enter-PASeasyGate -Name ('vault-'+$identity) -DataRoot $DataRoot -RunId $RunId -TimeoutSeconds $TimeoutSeconds))
        }
        if(-not $gates.Count){throw 'Vault operation has no resolved resource identity'}
        return $gates.ToArray()
    }catch{
        $admissionFailure=$_
        # No login has been dispatched. Only newly-created partial claims may be removed.
        foreach($gate in @($gates.ToArray())){
            try{try{if(-not $gate.PreexistingClaim){$gate.Complete()}}finally{$gate.Dispose()}}
            catch{Write-Verbose 'Partial Vault admission cleanup requires reconciliation'}
        }
        throw $admissionFailure
    }
}
function Exit-PASeasyVaultOperation {
    param([object[]]$Gates,[bool]$Succeeded=$false)
    $failure=$null
    foreach($gate in @($Gates)){
        try{try{if($Succeeded){$gate.Complete()}}finally{$gate.Dispose()}}
        catch{if(-not $failure){$failure=$_}}
    }
    if($failure){throw $failure}
}
function New-PASeasyBorrowedVaultLease {
    param([string]$Address,[string]$RunId,[string]$DataRoot,[object[]]$Gates)
    $lease=[pscustomobject]@{PSTypeName='PASeasyInstall.BorrowedVaultLease';Address=$Address;RunId=$RunId;DataRoot=[IO.Path]::GetFullPath($DataRoot).TrimEnd('\');OwnerPID=$PID;OwnerThread=[Threading.Thread]::CurrentThread.ManagedThreadId;Gates=@($Gates)}
    Assert-PASeasyBorrowedVaultLease $lease $RunId
    return $lease
}
function Assert-PASeasyBorrowedVaultLease {
    param($Lease,[string]$RunId)
    if(-not $Lease -or $Lease.PSObject.TypeNames -notcontains 'PASeasyInstall.BorrowedVaultLease' -or $Lease.OwnerPID -ne $PID -or $Lease.OwnerThread -ne [Threading.Thread]::CurrentThread.ManagedThreadId -or $Lease.RunId -cne $RunId){throw 'PAExecUnknown: borrowed Vault lease does not belong to this controller/run/thread'}
    $root=Assert-PASeasyCoordinationRoot
    $expected=@(foreach($identity in @(Get-PASeasyResourceIdentity $Lease.Address)){
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$key=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(('vault-'+$identity).ToLowerInvariant()))).Replace('-','')}finally{$sha.Dispose()}
        Join-Path $root ($key+'.json')
    })
    if(@($Lease.Gates).Count -ne $expected.Count -or -not $expected.Count){throw 'PAExecUnknown: borrowed Vault lease has the wrong resource set'}
    $seen=@{}
    foreach($gate in @($Lease.Gates)){
        if($gate.Disposed -or $gate.Completed -or $gate.Mutex.SafeWaitHandle.IsClosed -or $gate.Path -notin $expected -or $seen.ContainsKey([string]$gate.Path)){throw 'PAExecUnknown: borrowed Vault lease is not live'}
        $seen[[string]$gate.Path]=$true
        $claim=Read-PASJson $gate.Path
        if(-not $claim -or $claim.RunId -cne $RunId -or $claim.StateRoot -ine $Lease.DataRoot){throw 'PAExecUnknown: borrowed Vault lease claim changed'}
    }
}
function Enter-PASeasyGate {
    param([Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$DataRoot,
          [Parameter(Mandatory)][string]$RunId,[int]$TimeoutSeconds=30)
    $root=Assert-PASeasyCoordinationRoot
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Name.ToLowerInvariant())))).Replace('-','')}finally{$sha.Dispose()}
    $security=[Security.AccessControl.MutexSecurity]::new()
    $security.AddAccessRule([Security.AccessControl.MutexAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-11'),[Security.AccessControl.MutexRights]'Synchronize,Modify','Allow'))
    $created=$false
    $mutexName='Global\PASeasyInstall-'+$key
    $rights=[Security.AccessControl.MutexRights]'Synchronize,Modify'
    try{$mutex=[Threading.Mutex]::OpenExisting($mutexName,$rights)}
    catch [Threading.WaitHandleCannotBeOpenedException]{
        try{$mutex=[Threading.Mutex]::new($false,$mutexName,[ref]$created,$security)}
        catch [UnauthorizedAccessException]{$mutex=[Threading.Mutex]::OpenExisting($mutexName,$rights)}
    }
    $held=$false
    try{
        try{$held=$mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))}catch [Threading.AbandonedMutexException]{$held=$true}
        if(-not $held){throw "Gate '$Name' held by another process"}
        $path=Join-Path $root ($key+'.json')
        $stateRoot=[IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
        $preexistingClaim=Test-Path -LiteralPath $path
        if($preexistingClaim){
            if((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Gate journal is a reparse point'}
            $previous=Read-PASJson $path
            if(-not $previous -or $previous.RunId -ne $RunId -or $previous.StateRoot -ne $stateRoot){throw "Unreconciled resource '$Name'; resume its owning run before starting another deployment"}
        }else{
            $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
            try{$bytes=[Text.Encoding]::UTF8.GetBytes((@{RunId=$RunId;StateRoot=$stateRoot;CreatedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        }
        $gate=[pscustomobject]@{Mutex=$mutex;Path=$path;Completed=$false;Disposed=$false;PreexistingClaim=[bool]$preexistingClaim}
        $gate | Add-Member ScriptMethod Complete {$this.Completed=$true}
        $gate | Add-Member ScriptMethod Dispose {
            if($this.Disposed){return}
            try{if($this.Completed){[IO.File]::Delete($this.Path)}}finally{$this.Mutex.ReleaseMutex();$this.Mutex.Dispose();$this.Disposed=$true}
        }
        return $gate
    }catch{if($held){$mutex.ReleaseMutex()};$mutex.Dispose();throw}
}
