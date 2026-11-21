BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    . (Join-Path $root 'PASeasyInstall/Recipes/WindowsComponent/Ownership.ps1')
    $prepare = & (Get-Module PASeasyInstall) { Get-PASWindowsStagePreparation }
    $prepareFile = & (Get-Module PASeasyInstall) { Get-PASWindowsFilePreparation }
}
Describe 'Stable upload preparation and validation' {
    It 'prepares a protected file and validates it without truncating content or changing privilege state' {
        $path = Join-Path $TestDrive 'upload\payload.zip'
        $before = (Get-PASeasyRestorePrivilegeState).Attributes
        $null = & $prepareFile -Destination $path
        [IO.File]::WriteAllText($path, 'known partial upload')
        $hash = (Get-FileHash $path).Hash
        $acl = (Get-Acl $path).Sddl
        (& $prepareFile -Destination $path -ValidateOnly $true).Validated | Should -BeTrue
        (Get-FileHash $path).Hash | Should -BeExactly $hash
        (Get-Acl $path).Sddl | Should -BeExactly $acl
        (Get-Acl $path).GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -BeExactly 'S-1-5-32-544'
        (Get-PASeasyRestorePrivilegeState).Attributes | Should -Be $before
    }
    It 'prepares a private relay parent without creating a destination that would mask absence' {
        $path = Join-Path $TestDrive 'relay\server.key'
        $null = & $prepareFile -Destination $path -CreateFile $false
        Test-Path $path | Should -BeFalse
        (Get-Acl (Split-Path $path)).GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -BeExactly 'S-1-5-32-544'
    }
    It 'refuses untrusted existing media and reparse ancestors without touching their data' {
        $directory = Join-Path $TestDrive 'foreign-upload'
        New-Item $directory -ItemType Directory | Out-Null
        $path = Join-Path $directory 'payload.zip'
        [IO.File]::WriteAllText($path, 'retain')
        $acl = Get-Acl $path
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'))
        Invoke-PASeasyWithRestorePrivilege { ([IO.FileInfo]::new($path)).SetAccessControl($acl) }
        { & $prepareFile -Destination $path } | Should -Throw '*untrusted owner*'
        [IO.File]::ReadAllText($path) | Should -BeExactly 'retain'
        $link = Join-Path $TestDrive 'upload-link'
        New-Item $link -ItemType Junction -Target $directory | Out-Null
        { & $prepareFile -Destination (Join-Path $link 'other.zip') } | Should -Throw '*reparse*'
        Test-Path (Join-Path $directory 'other.zip') | Should -BeFalse
    }
}
Describe 'Stable remote stage and lease ownership' {
    It 'creates stable protected roots and immutable lease ownership without retaining a token privilege' {
        $path = Join-Path $TestDrive 'stage'
        $before = (Get-PASeasyRestorePrivilegeState).Attributes
        (& $prepare -Root $path -LockKey host -RunId run0001).Message | Should -Be 'acquired'
        foreach ($relative in @('', 'attempts', 'locks', 'locks/host', 'locks/host/owner.txt')) {
            $entry = if ($relative) { Join-Path $path $relative }else { $path }
            (Get-Acl $entry).GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -Be 'S-1-5-32-544'
        }
        (& $prepare -Root $path -LockKey host -RunId run0002).Message | Should -Be 'locked:run0001'
        (& $prepare -Root $path -LockKey host -RunId run0002 -Release $true).Message | Should -Be 'held:run0001'
        Test-Path (Join-Path $path 'locks/host/owner.txt') | Should -BeTrue
        (& $prepare -Root $path -LockKey host -RunId run0001 -Release $true).Message | Should -Be 'released'
        (& $prepare -Root $path -LockKey host -RunId run0001 -Release $true).Message | Should -Be 'none'
        Test-Path (Join-Path $path 'locks/host') | Should -BeFalse
        (Get-PASeasyRestorePrivilegeState).Attributes | Should -Be $before
    }
    It 'refuses an untrusted existing root before creating a lease or attempt parent' {
        $path = Join-Path $TestDrive 'foreign'
        New-Item $path -ItemType Directory | Out-Null
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'))
        Invoke-PASeasyWithRestorePrivilege { ([IO.DirectoryInfo]::new($path)).SetAccessControl($acl) }
        { & $prepare -Root $path -LockKey host -RunId run0003 } | Should -Throw '*untrusted owner*'
        Test-Path (Join-Path $path 'locks') | Should -BeFalse
        Test-Path (Join-Path $path 'attempts') | Should -BeFalse
    }
    It 'rejects relative, volume and operating-system roots' {
        foreach ($path in @('relative', [IO.Path]::GetPathRoot($TestDrive), $env:SystemRoot)) {
            { & $prepare -Root $path -LockKey host -RunId run0004 } | Should -Throw
        }
    }
}
