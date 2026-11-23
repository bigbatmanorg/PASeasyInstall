BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
}
Describe 'Lab stability: dependency compilation and finalization' {
    It 'fails closed when the plan contains an undeclared readiness signal' {
        InModuleScope PASeasyInstall {
            $cfg = @{ components = @(@{ id = 'pvwa01'; type = 'PVWA'; options = @{} }) }
            $signals = New-PASLaneSignals -Config $cfg
            try {
                { Get-PASLaneGate -Signals $signals -Names @('Cert:unknown') } |
                    Should -Throw '*Invalid workflow dependencies*'
            } finally {
                foreach ($signal in @($signals.Values)) { $signal.Dispose() }
            }
        }
    }
    It 'rejects a component that waits for its own certificate before starting' {
        InModuleScope PASeasyInstall {
            $cfg = @{
                activeDirectory = @{mode = 'None'; join = @()}
                components = @(
                    @{id = 'vault'; type = 'Vault'; host = 'v'; options = @{}},
                    @{id = 'pvwa01'; type = 'PVWA'; host = 'w'; options = @{pvwaTrustFrom = 'pvwa01'}}
                )
            }
            $plan = @(@{Id = 'vault'; Type = 'Vault'}, @{Id = 'pvwa01'; Type = 'PVWA'})
            $lanes = @(Get-PASRunLanes -Config $cfg -PlanItems $plan)
            { Assert-PASLaneSignalPlan -Config $cfg -Lanes $lanes } |
                Should -Throw '*Cyclic or forward dependency*'
        }
    }
    It 'accepts a valid Primary -> PVWA -> CPM -> PSM lane plan' {
        InModuleScope PASeasyInstall {
            $cfg = @{
                activeDirectory = @{mode = 'None'; join = @()}
                components = @(
                    @{id = 'vault'; type = 'Vault'; host = 'v'; options = @{}},
                    @{id = 'pvwa01'; type = 'PVWA'; host = 'w'; options = @{}},
                    @{id = 'cpm01'; type = 'CPM'; host = 'w'; options = @{}},
                    @{id = 'psm01'; type = 'PSM'; host = 'p'; options = @{}}
                )
            }
            $plan = @(@{Id = 'vault'; Type = 'Vault'}, @{Id = 'pvwa01'; Type = 'PVWA'},
                      @{Id = 'cpm01'; Type = 'CPM'}, @{Id = 'psm01'; Type = 'PSM'})
            $lanes = @(Get-PASRunLanes -Config $cfg -PlanItems $plan)
            { Assert-PASLaneSignalPlan -Config $cfg -Lanes $lanes } | Should -Not -Throw
        }
    }
    It 'does not bind PTA trust to PSMP or to DR replication' {
        InModuleScope PASeasyInstall {
            $cfg = @{components = @(
                @{id='vault';type='Vault';options=@{}},
                @{id='dr';type='DRVault';options=@{}},
                @{id='pvwa01';type='PVWA';options=@{}},
                @{id='psm01';type='PSM';options=@{}},
                @{id='psmp01';type='PSMP';options=@{}},
                @{id='pta01';type='PTA';options=@{}},
                @{id='gw01';type='HTML5GW';options=@{}}
            )}
            $jobs = @(Get-PASParallelFinalizationJobs -Config $cfg)
            $jobs.Count | Should -Be 2
            $pta = @($jobs | Where-Object Name -eq 'PtaTrust')[0]
            $gw = @($jobs | Where-Object Name -eq 'GatewayRegistration')[0]
            $pta.DependsOn | Should -Contain 'Done:pvwa01'
            $pta.DependsOn | Should -Contain 'Done:pta01'
            $pta.DependsOn | Should -Not -Contain 'Done:psmp01'
            $pta.DependsOn | Should -Not -Contain 'Done:dr'
            $gw.DependsOn | Should -Contain 'Done:psm01'
            $gw.DependsOn | Should -Contain 'Done:gw01'
            # The gateway restarts the PVWA application pool; PTA registers through that PVWA: one after the other.
            $gw.DependsOn | Should -Contain 'Done:pta01'
            $gw.DependsOn | Should -Not -Contain 'Done:psmp01'
            $gw.DependsOn | Should -Not -Contain 'Done:dr'
        }
    }
    It 'includes explicit mutating archive preparation in the public PSMP catalog' {
        $stages = @(Get-PASStageCatalog -Component PSMP | ForEach-Object Stage)
        [array]::IndexOf($stages, 'preflight') | Should -BeLessThan ([array]::IndexOf($stages, 'prepare-tools'))
        [array]::IndexOf($stages, 'prepare-tools') | Should -BeLessThan ([array]::IndexOf($stages, 'extract'))
    }
    It 'defaults to one custom-count deployment path in the desktop' {
        . (Get-PASTestModulePath 'Desktop/Model.ps1')
        $state = New-PASUIState
        $state.Preset | Should -BeExactly 'custom'
        $state.VaultMode | Should -BeExactly 'Primary'
        $state.Counts.PVWA | Should -BeGreaterThan 0
    }
    It 'waits for every component on the first PVWA server before an integration runs there' {
        InModuleScope PASeasyInstall {
            $cfg = @{components = @(
                @{id='vault';type='Vault';host='v';options=@{}},
                @{id='pvwa01';type='PVWA';host='w';options=@{}},
                @{id='cpm01';type='CPM';host='w';options=@{}},
                @{id='psm01';type='PSM';host='w';options=@{}},
                @{id='pta01';type='PTA';host='t';options=@{}}
            )}
            $pta = @(Get-PASParallelFinalizationJobs -Config $cfg | Where-Object Name -eq 'PtaTrust')[0]
            $pta.DependsOn | Should -Contain 'Done:cpm01'
            $pta.DependsOn | Should -Contain 'Done:psm01'
            @($pta.DependsOn | Select-Object -Unique).Count | Should -Be @($pta.DependsOn).Count
        }
    }
    It 'gives the integration lane a Vault gate, so gateway registration waits for its turn' {
        $source = Get-Content -Raw (Get-PASTestModulePath 'Private/Run/Lanes.ps1')
        $source | Should -Match ('Lane = ''integrations''[^\r\n]*\r?\n(\s*#[^\r\n]*\r?\n)*\s*VaultGate = @\{ Wait = @\(\); Cancel = @\(\$Shared\.Signals\.Cancel\)')
    }
    It 'gives prepare-tools more time than its two package manager calls' {
        InModuleScope PASeasyInstall {
            $source = Get-Content -Raw (Join-Path (Get-PASModuleRoot) 'Private/Config/Planning.ps1')
            $source | Should -Match "Id = 'prepare-tools'(?s).{0,400}TimeoutSeconds = 1800"
        }
    }
    It 'accepts two PVWAs with a CPM next to the first one (lane-level cycle, no component deadlock)' {
        InModuleScope PASeasyInstall {
            $cfg = @{
                activeDirectory = @{mode = 'None'; join = @()}
                components = @(
                    @{id = 'vault'; type = 'Vault'; host = 'v'; options = @{}},
                    @{id = 'pvwa01'; type = 'PVWA'; host = 'w1'; options = @{}},
                    @{id = 'cpm01'; type = 'CPM'; host = 'w1'; options = @{}},
                    @{id = 'pvwa02'; type = 'PVWA'; host = 'w2'; options = @{}},
                    @{id = 'cpm02'; type = 'CPM'; host = 'c2'; options = @{}},
                    @{id = 'psm01'; type = 'PSM'; host = 'p'; options = @{}}
                )
            }
            $plan = @($cfg.components | ForEach-Object { @{Id = $_.id; Type = $_.type} })
            $lanes = @(Get-PASRunLanes -Config $cfg -PlanItems $plan)
            { Assert-PASLaneSignalPlan -Config $cfg -Lanes $lanes } | Should -Not -Throw
        }
    }
}
