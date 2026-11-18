BeforeAll {
 . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.PSM/Recipes/WindowsComponent/Psm.ps1')
}
Describe 'PSM fixed vendor backup directory isolation' {
 BeforeEach {
  $script:acl=[Security.AccessControl.DirectorySecurity]::new()
  $script:acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICIIO;GA;;;CO)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;CI;0x100026;;;BU)')
  $caseRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));New-Item $caseRoot -ItemType Directory|Out-Null
  $dir=Join-Path $caseRoot 'temp';New-Item $dir -ItemType Directory|Out-Null
  $audit=Join-Path $caseRoot 'audit'
  Mock Get-Acl {$script:acl}
  Mock Set-Acl {
   $script:acl=[Security.AccessControl.DirectorySecurity]::new()
   $script:acl.SetSecurityDescriptorSddlForm('O:SYG:SY'+$AclObject.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::Access))
  }
 }
 It 'removes only root creation while preserving child creation and root traversal' {
  Protect-PASeasyPsmTempDirectory -DirectoryPath $dir -AuditRoot $audit
  Should -Invoke Set-Acl -Exactly 1
  {Assert-PASeasyPsmTempDirectory $dir}|Should -Not -Throw
  $users=@($script:acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|Where-Object {$_.IdentityReference.Value -eq 'S-1-5-32-545'})
  @($users|Where-Object {$_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly}).Count|Should -Be 1
  $root=@($users|Where-Object {$_.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None})
  ($root[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::ExecuteFile)|Should -Not -Be 0
  ($root[0].FileSystemRights -band [Security.AccessControl.FileSystemRights]::CreateFiles)|Should -Be 0
  @(Get-ChildItem $audit -File).Count|Should -Be 1
 }
 It 'is idempotent after the isolated root is verified' {
  Protect-PASeasyPsmTempDirectory -DirectoryPath $dir -AuditRoot $audit
  Protect-PASeasyPsmTempDirectory -DirectoryPath $dir -AuditRoot $audit
  Should -Invoke Set-Acl -Exactly 1
 }
 It 'rejects untrusted delete-child before writing audit or changing ACL' {
  $script:acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'DeleteSubdirectoriesAndFiles','Allow'))
  {Protect-PASeasyPsmTempDirectory -DirectoryPath $dir -AuditRoot $audit}|Should -Throw '*untrusted delete*'
  Should -Invoke Set-Acl -Exactly 0
  Test-Path $audit|Should -BeFalse
 }
 It 'rejects untrusted inherited file writing instead of changing child permissions' {
  $script:acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'Write','ObjectInherit','InheritOnly','Allow'))
  {Protect-PASeasyPsmTempDirectory -DirectoryPath $dir -AuditRoot $audit}|Should -Throw '*inherited file writes*'
  Should -Invoke Set-Acl -Exactly 0
 }
 It 'rejects unknown groups with full control' {
  $script:acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-11'),'FullControl','Allow'))
  {Protect-PASeasyPsmTempDirectory -DirectoryPath $dir -AuditRoot $audit}|Should -Throw '*untrusted delete*'
  Should -Invoke Set-Acl -Exactly 0
 }
 It 'rejects propagation semantics that cannot be preserved exactly' {
  $script:acl=[Security.AccessControl.DirectorySecurity]::new()
  $script:acl.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;CINP;0x100026;;;BU)')
  {Protect-PASeasyPsmTempDirectory -DirectoryPath $dir -AuditRoot $audit}|Should -Throw '*noncanonical creation*'
  Should -Invoke Set-Acl -Exactly 0
 }
 It 'rejects an untrusted owner' {
  $script:acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'))
  {Protect-PASeasyPsmTempDirectory -DirectoryPath $dir -AuditRoot $audit}|Should -Throw '*untrusted owner*'
  Should -Invoke Set-Acl -Exactly 0
 }
 It 'detects a failed effective ACL update by independent readback' {
  Mock Set-Acl {}
  {Protect-PASeasyPsmTempDirectory -DirectoryPath $dir -AuditRoot $audit}|Should -Throw '*untrusted root creation*'
 }
 It 'rejects a reparse target before any audit or mutation' {
  Mock Get-Item {[pscustomobject]@{PSIsContainer=$true;Attributes=[IO.FileAttributes]::ReparsePoint}}
  {Protect-PASeasyPsmTempDirectory -DirectoryPath $dir -AuditRoot $audit}|Should -Throw '*regular directory*'
  Should -Invoke Set-Acl -Exactly 0
 }
}

Describe 'PSM backup ancestor replacement prevention' {
 It 'rejects applicable untrusted <rights> on an ancestor' -TestCases @(
  @{rights='DeleteSubdirectoriesAndFiles'},@{rights='Delete'},@{rights='ChangePermissions'},@{rights='TakeOwnership'},@{rights='FullControl'}
 ) {
  param($rights)
  $a=[Security.AccessControl.DirectorySecurity]::new()
  $a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),$rights,'Allow'))
  {Assert-PASeasyPsmAncestorAcl -Acl $a}|Should -Throw '*ancestor permits untrusted*'
 }
 It 'allows harmless ancestor root creation and child-only grants' {
  $a=[Security.AccessControl.DirectorySecurity]::new()
  $a.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;OICI;FA;;;BA)(A;;0x100026;;;BU)(A;CIIO;FA;;;BU)')
  {Assert-PASeasyPsmAncestorAcl -Acl $a}|Should -Not -Throw
 }
 It 'checks ancestor ACLs in the actual backup traversal' {
  $backup='C:\Windows\Temp\fixture.reg'
  Mock Assert-PASeasyPsmTlsBackupData {}
  Mock Get-Item {[pscustomobject]@{PSIsContainer=($LiteralPath -notlike '*fixture.reg');Attributes=[IO.FileAttributes]::Normal}}
  Mock Get-Acl {$a=[Security.AccessControl.DirectorySecurity]::new();$a.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;;0x40;;;BU)');$a}
  Mock Get-Acl {$a=[Security.AccessControl.DirectorySecurity]::new();$a.SetSecurityDescriptorSddlForm('O:SYG:SYD:P(A;;FA;;;SY)');$a} -ParameterFilter {$LiteralPath -like '*fixture.reg'}
  {Assert-PASeasyPsmTlsBackupTrusted -BackupPath $backup}|Should -Throw '*ancestor permits untrusted*'
 }
}
