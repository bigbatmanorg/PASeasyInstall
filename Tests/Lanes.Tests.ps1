# A parallel run: which lanes a configuration has, what each component waits for, and how waiting ends.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    function New-LaneConfig {
        # A configuration as the lane functions read it: hosts, components in plan order, domain settings.
        param([object[]]$Components, [string[]]$Join = @(), [string]$DomainMode = 'None')
        return @{
            components = @($Components | ForEach-Object { @{ id = $_[0]; type = $_[1]; host = $_[2]; options = $(if ($_.Count -gt 3) { $_[3] } else { @{} }) } })
            activeDirectory = @{ mode = $DomainMode; join = $Join }
        }
    }
    function Get-Lanes {
        param($Config)
        $items = @($Config.components | ForEach-Object { [pscustomobject]@{ Id = $_.id; Type = $_.type } })
        return InModuleScope PASeasyInstall -Parameters @{ Config = $Config; Items = $items } {
            param($Config, $Items)
            Get-PASRunLanes -Config $Config -PlanItems $Items
        }
    }
}

Describe 'Lanes of a parallel run' {
    It 'gives every server one lane and keeps the components of a server in plan order' {
        $config = New-LaneConfig @(
            @('vault', 'Vault', 'h-vault'), @('dr', 'DRVault', 'h-dr'), @('pvwa01', 'PVWA', 'h-web'), @('cpm01', 'CPM', 'h-web'),
            @('psm01', 'PSM', 'h-psm'), @('psmp01', 'PSMP', 'h-linux'), @('gw01', 'HTML5GW', 'h-linux'))
        $lanes = @(Get-Lanes $config)
        ($lanes | ForEach-Object { $_.Name }) -join ',' | Should -Be 'vault,h-web,h-psm,h-linux'
        ($lanes[0].Components -join ',') | Should -Be 'vault,dr'
        ($lanes[1].Components -join ',') | Should -Be 'pvwa01,cpm01'
        ($lanes[3].Components -join ',') | Should -Be 'psmp01,gw01'
        @($lanes | Where-Object { $_.Join }).Count | Should -Be 0
    }
    It 'starts with the forest and marks the servers that are joined first' {
        $config = New-LaneConfig -DomainMode New -Join @('h-web', 'h-psm') -Components @(
            @('ad', 'AD', 'h-dc'), @('vault', 'Vault', 'h-vault'), @('pvwa01', 'PVWA', 'h-web'), @('psm01', 'PSM', 'h-psm'), @('psmp01', 'PSMP', 'h-linux'))
        $lanes = @(Get-Lanes $config)
        ($lanes | ForEach-Object { $_.Name }) -join ',' | Should -Be 'ad,vault,h-web,h-psm,h-linux'
        ($lanes | Where-Object { $_.Join } | ForEach-Object { $_.Name }) -join ',' | Should -Be 'h-web,h-psm'
        $lanes[0].Kind | Should -Be 'AD'
    }
    It 'has no Vault lane when the Vault exists already, and joins a server that gets no component' {
        $config = New-LaneConfig -DomainMode Existing -Join @('h-extra') -Components @(, @('psm01', 'PSM', 'h-psm'))
        $lanes = @(Get-Lanes $config)
        ($lanes | ForEach-Object { $_.Name }) -join ',' | Should -Be 'h-psm,h-extra'
        $lanes[1].Join | Should -BeTrue
        @($lanes[1].Components).Count | Should -Be 0
    }
    It 'installs a component on the Vault server after the Vault' {
        $config = New-LaneConfig @(@('vault', 'Vault', 'h-one'), @('pvwa01', 'PVWA', 'h-one'))
        $lanes = @(Get-Lanes $config)
        $lanes.Count | Should -Be 1
        ($lanes[0].After -join ',') | Should -Be 'pvwa01'
    }
}

Describe 'What a component of a parallel run waits for' {
    BeforeAll {
        $script:config = New-LaneConfig @(
            @('vault', 'Vault', 'h-vault'), @('pvwa01', 'PVWA', 'h-web'), @('pvwa02', 'PVWA', 'h-web2'),
            @('cpm01', 'CPM', 'h-web', @{ pvwaTrustFrom = 'pvwa01' }), @('psm01', 'PSM', 'h-psm'), @('pta01', 'PTA', 'h-pta', @{ pvwaTrustFrom = 'pvwa01' }))
        function Get-Gate([string]$Id) {
            $component = @($script:config.components | Where-Object { $_.id -eq $Id })[0]
            return InModuleScope PASeasyInstall -Parameters @{ Config = $script:config; Component = $component } {
                param($Config, $Component)
                Get-PASLaneComponentGate -Config $Config -Component $Component
            }
        }
    }
    It 'lets the first PVWA register as soon as the Vault is there, and announce it' {
        $gate = Get-Gate 'pvwa01'
        ($gate.VaultAfter -join ',') | Should -Be 'Vault'
        ($gate.StepSignals['register'] -join ',') | Should -Be 'Registered:pvwa01,PvwaRegistered'
        ($gate.StepSignals['certificate'] -join ',') | Should -Be 'Cert:pvwa01'
        $gate.DoneSignals | Should -Contain 'Done:pvwa01'
    }
    It 'registers in the order PVWA, CPM, then the rest' {
        ((Get-Gate 'pvwa02').VaultAfter -join ',') | Should -Be 'Vault,PvwaRegistered'
        ((Get-Gate 'cpm01').VaultAfter -join ',') | Should -Be 'Vault,Registered:pvwa01,Registered:pvwa02'
        ((Get-Gate 'cpm01').StepSignals['register'] -join ',') | Should -Be 'Registered:cpm01'
        ((Get-Gate 'psm01').VaultAfter -join ',') | Should -Be 'Vault,PvwaRegistered,Registered:cpm01'
        (Get-Gate 'psm01').StartAfter.Count | Should -Be 0
    }
    It 'starts a component that trusts the PVWA certificate only when every PVWA has one' {
        ((Get-Gate 'cpm01').StartAfter -join ',') | Should -Be 'Cert:pvwa01,Cert:pvwa02'
    }
    It 'configures PTA only when every PVWA is finished' {
        ((Get-Gate 'pta01').VaultAfter -join ',') | Should -Be 'Vault,Done:pvwa01,Done:pvwa02,Registered:cpm01'
    }
}

Describe 'Signals and waiting of a parallel run' {
    It 'sets from the start what the run will never set' {
        $config = New-LaneConfig @(, @('psm01', 'PSM', 'h-psm'))
        InModuleScope PASeasyInstall -Parameters @{ Config = $config } {
            param($Config)
            $signals = New-PASLaneSignals -Config $Config
            try {
                $signals.Domain.WaitOne(0) | Should -BeTrue
                $signals.Vault.WaitOne(0) | Should -BeTrue
                $signals.PvwaRegistered.WaitOne(0) | Should -BeTrue
                $signals.Cancel.WaitOne(0) | Should -BeFalse
            } finally {
                foreach ($signal in @($signals.Values)) { $signal.Dispose() }
            }
        }
    }
    It 'keeps the Vault and the first PVWA closed until they are installed' {
        $config = New-LaneConfig @(@('vault', 'Vault', 'h-vault'), @('ad', 'AD', 'h-dc'), @('pvwa01', 'PVWA', 'h-web'))
        InModuleScope PASeasyInstall -Parameters @{ Config = $config } {
            param($Config)
            $signals = New-PASLaneSignals -Config $Config
            try {
                foreach ($name in 'Domain', 'Vault', 'PvwaRegistered', 'Cert:pvwa01', 'Done:pvwa01') {
                    $signals[$name].WaitOne(0) | Should -BeFalse -Because $name
                }
                Test-PASVaultGateOpen @{ Wait = @($signals.Vault); Cancel = $signals.Cancel } | Should -BeFalse
                [void]$signals.Vault.Set()
                Test-PASVaultGateOpen @{ Wait = @($signals.Vault); Cancel = $signals.Cancel } | Should -BeTrue
                Wait-PASVaultGate @{ Wait = @($signals.Vault); Cancel = $signals.Cancel } | Should -BeFalse
            } finally {
                foreach ($signal in @($signals.Values)) { $signal.Dispose() }
            }
        }
    }
    It 'ends a wait with PASLaneStopped when the run is being stopped' {
        InModuleScope PASeasyInstall {
            $wait = New-Object System.Threading.ManualResetEvent -ArgumentList $false
            $cancel = New-Object System.Threading.ManualResetEvent -ArgumentList $true
            try {
                { Wait-PASVaultGate @{ Wait = @($wait); Cancel = $cancel } } | Should -Throw 'PASLaneStopped:*'
            } finally {
                $wait.Dispose()
                $cancel.Dispose()
            }
        }
    }
    It 'gives up waiting for the Vault lock when the run is being stopped' {
        InModuleScope PASeasyInstall {
            $address = 'lane-test-' + [guid]::NewGuid().ToString('N')
            # Another thread holds the lock: a named mutex belongs to the thread that took it.
            $holder = [powershell]::Create()
            $release = New-Object System.Threading.ManualResetEvent -ArgumentList $false
            $taken = New-Object System.Threading.ManualResetEvent -ArgumentList $false
            $cancel = New-Object System.Threading.ManualResetEvent -ArgumentList $true
            try {
                [void]$holder.AddScript({
                        param($Name, $Taken, $Release)
                        $mutex = New-Object System.Threading.Mutex -ArgumentList $false, $Name
                        [void]$mutex.WaitOne()
                        [void]$Taken.Set()
                        [void]$Release.WaitOne(30000)
                        $mutex.ReleaseMutex()
                        $mutex.Dispose()
                    }).AddArgument('Global\PASeasyInstall-Vault-' + $address).AddArgument($taken).AddArgument($release)
                $running = $holder.BeginInvoke()
                $taken.WaitOne(10000) | Should -BeTrue
                { Enter-PASVaultLock -Address $address -TimeoutSeconds 60 -Cancel $cancel } | Should -Throw 'PASLaneStopped:*'
                [void]$release.Set()
                [void]$holder.EndInvoke($running)
            } finally {
                [void]$release.Set()
                $holder.Dispose()
                $release.Dispose()
                $taken.Dispose()
                $cancel.Dispose()
            }
        }
    }
}
