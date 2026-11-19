# The plan shown before installing must match the composed deployment's real order: CPM, PSM and PSMP wait for
# the first PVWA (its registration creates the Vault objects they register against).
BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Orchestrator/PASeasyInstall.Orchestrator.psd1') -Force
}
Describe 'Plan dependencies' {
    It 'shows the first PVWA as a dependency of CPM, PSM and PSMP' {
        InModuleScope PASeasyInstall.Orchestrator {
            $cfg = [ordered]@{ name = 'Lab01'; vault = @{ existing = $false; address = '192.0.2.11' }; media = @{}; mediaRoot = ''; execution = @{ mode = 'Parallel' }
                hosts = [ordered]@{ v = @{ address = '192.0.2.11'; os = 'Windows' }; p = @{ address = '192.0.2.21'; os = 'Windows' }; c = @{ address = '192.0.2.22'; os = 'Windows' }; s = @{ address = '192.0.2.31'; os = 'Linux' } }
                components = @([ordered]@{ id = 'vault'; type = 'Vault'; host = 'v' }, [ordered]@{ id = 'pvwa01'; type = 'PVWA'; host = 'p'; options = @{} },
                    [ordered]@{ id = 'cpm01'; type = 'CPM'; host = 'c'; options = @{} }, [ordered]@{ id = 'psmp01'; type = 'PSMP'; host = 's'; options = @{} }) }
            $plan = [pscustomobject]@{ Name = 'Lab01'; ExecutionMode = ''; Items = @(
                    [pscustomobject]@{ Id = 'vault'; Type = 'Vault'; Host = 'v'; DependsOn = @() },
                    [pscustomobject]@{ Id = 'pvwa01'; Type = 'PVWA'; Host = 'p'; DependsOn = @('vault') },
                    [pscustomobject]@{ Id = 'cpm01'; Type = 'CPM'; Host = 'c'; DependsOn = @('vault') },
                    [pscustomobject]@{ Id = 'psmp01'; Type = 'PSMP'; Host = 's'; DependsOn = @('vault') }) }
            $out = Add-PASPlanDetail -Plan $plan -Configuration $cfg
            $deps = @{}; foreach ($i in $out.Items) { $deps[$i.Id] = (@($i.DependsOn) | Sort-Object) -join ',' }
            $deps['vault'] | Should -Be ''
            $deps['pvwa01'] | Should -Be 'vault'
            $deps['cpm01'] | Should -Be 'pvwa01,vault'
            $deps['psmp01'] | Should -Be 'pvwa01,vault'
        }
    }
}
