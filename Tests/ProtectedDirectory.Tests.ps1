BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1'); Import-PASTestModule
}
Describe 'Protected controller staging directories' {
    It 'removes an existing explicit broad write grant rather than merely adding an owner grant' {
        $path=Join-Path $TestDrive 'restricted';New-Item $path -ItemType Directory | Out-Null
        $acl=Get-Acl $path
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
        Set-Acl $path $acl
        & (Get-Module PASeasyInstall) {param($path) Protect-PASDirectory $path} $path
        $rules=(Get-Acl $path).GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])
        @($rules | Where-Object {$_.IdentityReference.Value -eq 'S-1-5-32-545'}).Count | Should -Be 0
        @($rules | Where-Object {$_.IsInherited}).Count | Should -Be 0
    }
    It 'refuses a volume root without altering it' {
        $root=[IO.Path]::GetPathRoot($TestDrive)
        $before=(Get-Acl $root).Sddl
        {& (Get-Module PASeasyInstall) {param($path) Protect-PASDirectory $path} $root} | Should -Throw '*volume root*'
        (Get-Acl $root).Sddl | Should -BeExactly $before
    }
}
