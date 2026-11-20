BeforeAll { . (Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall/Recipes/WindowsComponent/Ownership.ps1') }
Describe 'Bounded existing token restore privilege' {
    It 'restores the exact token attributes after success, nesting and an exception' {
        $before = Get-PASeasyRestorePrivilegeState
        $before.Present | Should -BeTrue
        Invoke-PASeasyWithRestorePrivilege {
            (Get-PASeasyRestorePrivilegeState).Enabled | Should -BeTrue
            Invoke-PASeasyWithRestorePrivilege { (Get-PASeasyRestorePrivilegeState).Enabled | Should -BeTrue }
            (Get-PASeasyRestorePrivilegeState).Enabled | Should -BeTrue
        }
        (Get-PASeasyRestorePrivilegeState).Attributes | Should -Be $before.Attributes
        { Invoke-PASeasyWithRestorePrivilege { throw 'fixture failure' } } | Should -Throw '*fixture failure*'
        (Get-PASeasyRestorePrivilegeState).Attributes | Should -Be $before.Attributes
    }
}
