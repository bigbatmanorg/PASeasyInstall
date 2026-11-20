# The plan shown before installing must match the real order: CPM, PSM and PSMP wait for the first PVWA
# (its registration creates the Vault objects they register against).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
}
Describe 'Plan dependencies' {
    It 'shows the first PVWA as a dependency of CPM, PSM and PSMP' {
        $cfg = New-PASLabConfiguration -Environment Lab01 -VaultMode Existing -ExistingVaultAddress 192.0.2.11 `
            -ControllerAddress 192.0.2.2 -SecurityProfile Lab -AcceptEula -Instances @(
            @{ Type = 'PSMP'; Name = 'PSMP01'; Address = '192.0.2.31' },
            @{ Type = 'CPM'; Name = 'CPM01'; Address = '192.0.2.22' },
            @{ Type = 'PSM'; Name = 'PSM01'; Address = '192.0.2.23' },
            @{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21' },
            @{ Type = 'PVWA'; Name = 'PVWA02'; Address = '192.0.2.24' })
        $plan = Get-PASLabPlan -Configuration $cfg
        $deps = @{}
        foreach ($item in $plan.Items) { $deps[$item.Id] = (@($item.DependsOn) | Sort-Object) -join ',' }
        $deps['pvwa01'] | Should -Be ''
        $deps['pvwa02'] | Should -Be ''
        $deps['cpm01'] | Should -Be 'pvwa01'
        $deps['psm01'] | Should -Be 'pvwa01'
        $deps['psmp01'] | Should -Be 'pvwa01'
        # Items come out in the order they are installed: every PVWA before the components that wait for it.
        $order = @($plan.Items | ForEach-Object { $_.Id })
        $order.IndexOf('pvwa01') | Should -BeLessThan $order.IndexOf('cpm01')
        $order.IndexOf('pvwa01') | Should -BeLessThan $order.IndexOf('psmp01')
    }
}
