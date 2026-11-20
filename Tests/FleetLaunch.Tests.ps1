# Composed deployment launch: a failed launch must not leave a "running" record that blocks the environment.
BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $env:PAS_EASY_DATA_ROOT = Join-Path $TestDrive 'data'
    Import-Module (Join-Path $repo 'Modules/PASeasyInstall.Orchestrator/PASeasyInstall.Orchestrator.psd1') -Force
    $script:config = [ordered]@{ schemaVersion = 2; name = 'FleetLaunch'; controllerAddress = '192.0.2.10'; mediaRoot = ''
        media = @{}; options = @{}; execution = @{ mode = 'Sequential' }
        security = @{ profile = 'Lab'; overrides = @{} }
        vault = @{ address = '192.0.2.11'; existing = $true; secretRef = 'VaultAdmin' }
        activeDirectory = @{ mode = 'None'; join = @() }
        hosts = @{ pvwa01 = @{ address = '192.0.2.21'; os = 'Windows'; user = 'Administrator'; credentialRef = 'pvwa01' } }
        components = @(@{ id = 'pvwa01'; type = 'PVWA'; host = 'pvwa01'; variant = 'Standard' }) }
}

Describe 'Composed deployment launch' {
    It 'marks the record LaunchFailed and removes the credential file when credentials cannot be protected' -Skip:($env:OS -ne 'Windows_NT') {
        InModuleScope PASeasyInstall.Orchestrator -Parameters @{ Config = $script:config } {
            param($Config)
            Mock Save-PASFleetEnvelope { param($Path) [IO.File]::WriteAllText($Path, 'partial'); throw [Security.Cryptography.CryptographicException]::new('Access is denied.') }
            { Start-PASFleet -Configuration $Config } | Should -Throw '*local session on the controller*'
            $dir = Get-ChildItem (Get-PASFleetRoot) -Directory | Sort-Object LastWriteTime | Select-Object -Last 1
            (Read-PASFleetJson (Join-Path $dir.FullName 'fleet.json')).status | Should -Be 'LaunchFailed'
            @(Get-ChildItem $dir.FullName -Filter 'auth-*').Count | Should -Be 0
        }
    }

    It 'does not let a stale launching record without a controller block the environment' -Skip:($env:OS -ne 'Windows_NT') {
        InModuleScope PASeasyInstall.Orchestrator -Parameters @{ Config = $script:config } {
            param($Config)
            $stale = Join-Path (Get-PASFleetRoot) ('a' * 32)
            New-Item -ItemType Directory -Force $stale | Out-Null
            Write-PASFleetJson (Join-Path $stale 'fleet.json') ([ordered]@{ schemaVersion = 1; id = ('a' * 32); name = $Config.name; status = 'Launching'
                startedUtc = [DateTime]::UtcNow.AddMinutes(-10).ToString('o'); controllerPid = $null; units = @() })
            Mock Save-PASFleetEnvelope { throw 'stop here: launch itself is not under test' }
            { Start-PASFleet -Configuration $Config } | Should -Throw '*stop here*'
            (Read-PASFleetJson (Join-Path $stale 'fleet.json')).status | Should -Be 'LaunchFailed'
        }
    }
}

Describe 'Composed deployment status after a unit is resumed' {
    It 'reports Succeeded once every unit run succeeded, even after the controller had given up' {
        InModuleScope PASeasyInstall.Orchestrator {
            $id = 'b' * 32; $dir = Get-PASFleetDirectory $id
            New-Item -ItemType Directory -Force $dir | Out-Null
            Write-PASFleetJson (Join-Path $dir 'fleet.json') ([ordered]@{ schemaVersion = 1; id = $id; name = 'Resumed'; status = 'Failed'; controllerPid = $null
                units = @([ordered]@{ id = 'pas-psm'; status = 'Failed'; runId = ('c' * 32); message = 'Interrupted' }) })
            Mock Get-PASRunRecord { [pscustomobject]@{ status = 'Succeeded' } }
            Mock Get-PASFleetEvents { @() }
            $s = Get-PASFleetSnapshot -FleetId $id
            $s.Status | Should -Be 'Succeeded'
            $s.Units[0].Status | Should -Be 'Succeeded'
            (Read-PASFleetJson (Join-Path $dir 'fleet.json')).status | Should -Be 'Succeeded'
        }
    }
    It 'stays Failed while a unit never ran' {
        InModuleScope PASeasyInstall.Orchestrator {
            $id = 'd' * 32; $dir = Get-PASFleetDirectory $id
            New-Item -ItemType Directory -Force $dir | Out-Null
            Write-PASFleetJson (Join-Path $dir 'fleet.json') ([ordered]@{ schemaVersion = 1; id = $id; name = 'Partial'; status = 'Failed'; controllerPid = $null
                units = @([ordered]@{ id = 'pas-psm'; status = 'Failed'; runId = ('e' * 32); message = 'x' }, [ordered]@{ id = 'pas-cpm'; status = 'Skipped'; runId = ''; message = 'x' }) })
            Mock Get-PASRunRecord { [pscustomobject]@{ status = 'Succeeded' } }
            Mock Get-PASFleetEvents { @() }
            (Get-PASFleetSnapshot -FleetId $id).Status | Should -Be 'Failed'
        }
    }
}
