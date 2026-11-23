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
        # The DR Vault has a lane of its own: it is installed next to the Primary, not after it.
        ($lanes | ForEach-Object { $_.Name }) -join ',' | Should -Be 'vault,dr,h-web,h-psm,h-linux'
        ($lanes[0].Components -join ',') | Should -Be 'vault'
        $lanes[1].Kind | Should -Be 'DR'
        ($lanes[1].Components -join ',') | Should -Be 'dr'
        ($lanes[2].Components -join ',') | Should -Be 'pvwa01,cpm01'
        ($lanes[4].Components -join ',') | Should -Be 'psmp01,gw01'
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

Describe 'The Vault workflows of a lane' {
    It 'gives the Vault lane the Primary and its test safe, and the DR lane the DR Vault' {
        InModuleScope PASeasyInstall {
            (@(Get-PASVaultWorkflowNames -WithDR $false -Part Primary) -join ',') | Should -Be 'VaultPrimaryOnly.psd1'
            @(Get-PASVaultWorkflowNames -WithDR $false -Part PrimaryTest).Count | Should -Be 0
            @(Get-PASVaultWorkflowNames -WithDR $false -Part DR).Count | Should -Be 0
            (@(Get-PASVaultWorkflowNames -WithDR $false) -join ',') | Should -Be 'VaultPrimaryOnly.psd1'
            (@(Get-PASVaultWorkflowNames -WithDR $true -Part Primary) -join ',') | Should -Be 'VaultPrimary-Phase1.psd1'
            (@(Get-PASVaultWorkflowNames -WithDR $true -Part PrimaryTest) -join ',') | Should -Be 'VaultPrimary-Phase2.psd1'
            (@(Get-PASVaultWorkflowNames -WithDR $true -Part DR) -join ',') | Should -Be 'VaultDR-Phase1.psd1,VaultDR-Phase2.psd1'
            (@(Get-PASVaultWorkflowNames -WithDR $true) -join ',') | Should -Be 'VaultPrimary-Phase1.psd1,VaultDR-Phase1.psd1,VaultPrimary-Phase2.psd1,VaultDR-Phase2.psd1'
            @(Get-PASVaultWorkflowNames -WithDR $true -Part Prepare).Count | Should -Be 0
        }
    }
    It 'creates the test safe without waiting for the DR Vault, and the DR Vault waits for the test safe' {
        $root = Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall/Recipes/Vault/Workflows'
        $primary = Import-PowerShellDataFile -Path (Join-Path $root 'VaultPrimary-Phase2.psd1')
        $dr = Import-PowerShellDataFile -Path (Join-Path $root 'VaultDR-Phase2.psd1')
        $primary.Steps[0].Id | Should -Be 'create-test-safe'
        $primary.Steps[0].ContainsKey('DependsOn') | Should -BeFalse
        $primary.Steps[0].RequiresVaultSession | Should -BeTrue
        ($primary.Steps[0].Publishes -join ',') | Should -Be 'test-safe-created'
        ($dr.Steps[0].DependsOn -join ',') | Should -Be 'test-safe-created'
    }
}

Describe 'A continued run leaves finished servers alone' {
    BeforeAll {
        $script:runDir = Join-Path ([IO.Path]::GetTempPath()) ('pas-lanes-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:runDir
        function Set-TargetState([string]$Target, [string]$Status) {
            $dir = Join-Path $script:runDir $Target
            $null = New-Item -ItemType Directory -Path $dir -Force
            Set-Content -LiteralPath (Join-Path $dir 'state.json') -Value (@{ status = $Status } | ConvertTo-Json) -Encoding UTF8
        }
        $script:laneConfig = New-LaneConfig @(
            @('vault', 'Vault', 'h-vault'), @('dr', 'DRVault', 'h-dr'), @('pvwa01', 'PVWA', 'h-web'), @('cpm01', 'CPM', 'h-cpm'), @('psm01', 'PSM', 'h-psm'))
        function Test-Finished([string]$Name) {
            $lane = @(Get-Lanes $script:laneConfig | Where-Object { $_.Name -eq $Name })[0]
            return InModuleScope PASeasyInstall -Parameters @{ Lane = $lane; Config = $script:laneConfig; Directory = $script:runDir } {
                param($Lane, $Config, $Directory)
                Test-PASLaneFinished -Lane $Lane -Config $Config -Directory $Directory
            }
        }
    }
    AfterAll {
        Remove-Item -LiteralPath $script:runDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'runs every lane of a new run' {
        foreach ($name in 'vault', 'dr', 'h-web', 'h-cpm', 'h-psm') {
            Test-Finished $name | Should -BeFalse -Because $name
        }
    }
    It 'skips a server whose journal says Succeeded and runs the one that failed' {
        Set-TargetState 'pvwa01' 'Succeeded'
        Set-TargetState 'cpm01' 'Failed'
        Set-TargetState 'psm01' 'Stopped'
        Test-Finished 'h-web' | Should -BeTrue
        Test-Finished 'h-cpm' | Should -BeFalse
        Test-Finished 'h-psm' | Should -BeFalse
    }
    It 'counts the Primary as finished only with its test safe, and the DR Vault only with its replication test' {
        Set-TargetState 'primary' 'Succeeded'
        Test-Finished 'vault' | Should -BeFalse
        Set-TargetState 'primary_final' 'Succeeded'
        Test-Finished 'vault' | Should -BeTrue
        Set-TargetState 'dr' 'Succeeded'
        Test-Finished 'dr' | Should -BeFalse
        Set-TargetState 'dr_final' 'Succeeded'
        Test-Finished 'dr' | Should -BeTrue
    }
    It 'always runs a server that is joined to a domain' {
        $joined = New-LaneConfig -DomainMode Existing -Join @('h-web') -Components @(, @('pvwa01', 'PVWA', 'h-web'))
        $lane = @(Get-Lanes $joined)[0]
        InModuleScope PASeasyInstall -Parameters @{ Lane = $lane; Config = $joined; Directory = $script:runDir } {
            param($Lane, $Config, $Directory)
            Test-PASLaneFinished -Lane $Lane -Config $Config -Directory $Directory | Should -BeFalse
        }
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
        ((Get-Gate 'cpm01').VaultAfter -join ',') | Should -Be 'Vault,PvwaRegistered,Registered:pvwa01,Registered:pvwa02'
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
    It 'stops only what depends on a server that failed' {
        $config = New-LaneConfig @(
            @('vault', 'Vault', 'h-vault'), @('dr', 'DRVault', 'h-dr'), @('pvwa01', 'PVWA', 'h-web'),
            @('cpm01', 'CPM', 'h-cpm', @{ pvwaTrustFrom = 'pvwa01' }), @('psm01', 'PSM', 'h-psm'), @('pta01', 'PTA', 'h-pta', @{ pvwaTrustFrom = 'pvwa01' }))
        $items = @($config.components | ForEach-Object { [pscustomobject]@{ Id = $_.id; Type = $_.type } })
        InModuleScope PASeasyInstall -Parameters @{ Config = $config; Items = $items } {
            param($Config, $Items)
            $lanes = @(Get-PASRunLanes -Config $Config -PlanItems $Items)
            $lane = @{}
            foreach ($entry in $lanes) { $lane[$entry.Name] = $entry }
            $psm = @($Config.components | Where-Object { $_.id -eq 'psm01' })[0]
            $psmNeeds = (Get-PASLaneComponentGate -Config $Config -Component $psm).VaultAfter

            # PTA and the DR Vault owe nothing: their failure stops nobody.
            @(Get-PASLaneOwedSignals -Config $Config -Lane $lane['h-pta']).Count | Should -Be 0
            @(Get-PASLaneOwedSignals -Config $Config -Lane $lane['dr']).Count | Should -Be 0

            # CPM fails: its registration was only an order, so PSM goes on.
            $signals = New-PASLaneSignals -Config $Config
            try {
                [void]$signals.Vault.Set()
                [void]$signals.PvwaRegistered.Set()
                $needs = @(Set-PASLaneFailed -Signals $signals -Owed (Get-PASLaneOwedSignals -Config $Config -Lane $lane['h-cpm']))
                $needs.Count | Should -Be 0
                Wait-PASVaultGate (Get-PASLaneGate $signals $psmNeeds) | Should -BeFalse
            } finally {
                foreach ($signal in @($signals.Values)) { $signal.Dispose() }
            }

            # PVWA fails: what needs it gives up, at once.
            $signals = New-PASLaneSignals -Config $Config
            try {
                [void]$signals.Vault.Set()
                $needs = @(Set-PASLaneFailed -Signals $signals -Owed (Get-PASLaneOwedSignals -Config $Config -Lane $lane['h-web']))
                $needs | Should -Contain 'PvwaRegistered'
                $needs | Should -Contain 'Cert:pvwa01'
                { Wait-PASVaultGate (Get-PASLaneGate $signals $psmNeeds) } | Should -Throw 'PASLaneStopped:*'
                { Wait-PASLaneSignal $signals @('Cert:pvwa01') } | Should -Throw 'PASLaneStopped:*'
            } finally {
                foreach ($signal in @($signals.Values)) { $signal.Dispose() }
            }

            # The Vault fails: everything that signs in to it gives up; what is already set stays set.
            $signals = New-PASLaneSignals -Config $Config
            try {
                [void]$signals['Cert:pvwa01'].Set()
                $needs = @(Set-PASLaneFailed -Signals $signals -Owed (Get-PASLaneOwedSignals -Config $Config -Lane $lane['vault']))
                ($needs -join ',') | Should -Be 'Vault'
                { Wait-PASVaultGate (Get-PASLaneGate $signals $psmNeeds) } | Should -Throw 'PASLaneStopped:*'
                Wait-PASVaultGate (Get-PASLaneGate $signals @('Cert:pvwa01')) | Should -BeFalse
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

Describe 'A damaged package in the media' {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $script:mediaDir = Join-Path ([IO.Path]::GetTempPath()) ('pas-damaged-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:mediaDir
        # A good package: a real ZIP. A damaged one: the same bytes with the end cut off.
        $inner = Join-Path $script:mediaDir 'inner'
        $null = New-Item -ItemType Directory -Path $inner
        Set-Content -LiteralPath (Join-Path $inner 'readme.txt') -Value ('x' * 4000)
        $script:good = Join-Path $script:mediaDir 'HTML5 Gateway-Rls-v15.0.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($inner, $script:good)
        $bytes = [IO.File]::ReadAllBytes($script:good)
        $script:bad = Join-Path $script:mediaDir 'HTML5 Gateway-Rls-v15.2.1.zip'
        [IO.File]::WriteAllBytes($script:bad, $bytes[0..($bytes.Length - 30)])
        Remove-Item -LiteralPath $inner -Recurse -Force
    }
    AfterAll {
        Remove-Item -LiteralPath $script:mediaDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'marks a package that is not a complete ZIP file and uses the good copy, although it is older' {
        $inventory = @(Get-PASMediaInventory -Path $script:mediaDir)
        ($inventory | Where-Object { $_.Name -eq 'HTML5 Gateway-Rls-v15.2.1.zip' }).Damaged | Should -BeTrue
        ($inventory | Where-Object { $_.Name -eq 'HTML5 Gateway-Rls-v15.0.zip' }).Damaged | Should -BeFalse
        $selection = Get-PASMediaSelection -Inventory $inventory -WarningVariable warned -WarningAction SilentlyContinue
        $selection['HTML5GW'].Name | Should -Be 'HTML5 Gateway-Rls-v15.0.zip'
        ($warned -join ' ') | Should -Match 'damaged'
    }
    It 'judges a package that lies inside a bigger file by its own last bytes' {
        # As inside a bundle that stores its packages: the good package, then the damaged one, then more bytes.
        $combined = Join-Path $script:mediaDir 'combined.bin'
        $goodBytes = [IO.File]::ReadAllBytes($script:good)
        $badBytes = [IO.File]::ReadAllBytes($script:bad)
        [IO.File]::WriteAllBytes($combined, [byte[]]($goodBytes + $badBytes + (New-Object byte[] 500)))
        InModuleScope PASeasyInstall -Parameters @{ Path = $combined; Good = $goodBytes.Length; Bad = $badBytes.Length } {
            param($Path, $Good, $Bad)
            Test-PASZipTail -Path $Path -Offset 0 -Length $Good | Should -BeTrue
            Test-PASZipTail -Path $Path -Offset $Good -Length $Bad | Should -BeFalse
        }
    }
}
