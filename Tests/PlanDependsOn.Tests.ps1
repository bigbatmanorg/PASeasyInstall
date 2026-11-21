# The plan shown before installing must match the real order: CPM, PSM and PSMP wait for the first PVWA
# (its registration creates the Vault objects they register against).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
}
Describe 'Plan dependencies' {
    It 'shows the first PVWA as a dependency of PSM and PSMP, and every PVWA as a dependency of a lab CPM' {
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
        # A lab CPM trusts the certificate of every PVWA of the deployment, so it waits for all of them.
        $deps['cpm01'] | Should -Be 'pvwa01,pvwa02'
        $deps['psm01'] | Should -Be 'pvwa01'
        $deps['psmp01'] | Should -Be 'pvwa01'
        # Items come out in the order they are installed: every PVWA before the components that wait for it.
        $order = @($plan.Items | ForEach-Object { $_.Id })
        $order.IndexOf('pvwa01') | Should -BeLessThan $order.IndexOf('cpm01')
        $order.IndexOf('pvwa01') | Should -BeLessThan $order.IndexOf('psmp01')
        $order.IndexOf('pvwa02') | Should -BeLessThan $order.IndexOf('cpm01')
    }
}

Describe 'CPM Vault user names' {
    It 'gives every further CPM instance its own Vault user' {
        $cfg = New-PASLabConfiguration -Environment Lab01 -VaultMode Existing -ExistingVaultAddress 192.0.2.11 `
            -ControllerAddress 192.0.2.2 -SecurityProfile Lab -AcceptEula -Instances @(
            @{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21' },
            @{ Type = 'CPM'; Name = 'CPM01'; Address = '192.0.2.22' },
            @{ Type = 'CPM'; Name = 'CPM02'; Address = '192.0.2.23' },
            @{ Type = 'CPM'; Name = 'CPM03'; Address = '192.0.2.24' })
        $users = @{}
        foreach ($component in @($cfg.components | Where-Object { $_.type -eq 'CPM' })) {
            $users[[string]$component.id] = [string]$component.options.cpmUser
        }
        $users['cpm01'] | Should -Be ''
        $users['cpm02'] | Should -Be 'PasswordManager2'
        $users['cpm03'] | Should -Be 'PasswordManager3'
    }
}
