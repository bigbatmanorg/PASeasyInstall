# Test-PASDeploymentStatus: the service-only probe opens no session; the authenticated probe holds the
# Vault lock (Locks.ps1) while its PVWA session is open and always releases it.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    $credential = [pscredential]::new('Administrator', (ConvertTo-SecureString 'SYNTHETIC_PUBLIC_HEALTH_SECRET' -AsPlainText -Force))
}
Describe 'Deployment status and authenticated health' {
    BeforeEach {
        $global:PAeasyHealthFixture = @{ Events = (New-Object System.Collections.ArrayList); Held = $false }
        Mock Get-PASComponentStatus -ModuleName PASeasyInstall {
            @([pscustomobject]@{ Component = 'pvwa'; Type = 'PVWA'; ServiceStatus = 'Running' },
                [pscustomobject]@{ Component = 'cpm'; Type = 'CPM'; ServiceStatus = 'Running' },
                [pscustomobject]@{ Component = 'psm'; Type = 'PSM'; ServiceStatus = 'Running' })
        }
        Mock Read-PASConfiguration -ModuleName PASeasyInstall {
            @{
                vault = @{ address = 'vault.alias' }
                components = @(@{
                        id = 'pvwa'
                        type = 'PVWA'
                        options = @{ pvwaUrl = 'https://pvwa.test/PasswordVault' }
                    })
            }
        }
        Mock Enter-PASVaultLock -ModuleName PASeasyInstall {
            [void]$global:PAeasyHealthFixture.Events.Add('lock:' + $Address)
            $global:PAeasyHealthFixture.Held = $true
            return [pscustomobject]@{ Address = $Address }
        }
        Mock Exit-PASVaultLock -ModuleName PASeasyInstall {
            if ($null -eq $Lock) { return }
            [void]$global:PAeasyHealthFixture.Events.Add('unlock')
            $global:PAeasyHealthFixture.Held = $false
        }
        Mock Invoke-PASAuthenticatedWebHealth -ModuleName PASeasyInstall {
            $global:PAeasyHealthFixture.Held | Should -BeTrue
            [void]$global:PAeasyHealthFixture.Events.Add('authenticate')
            [pscustomobject]@{
                SessionState = 'Closed'
                FailureCode = ''
                PVWA = @{
                    Passed = $true
                    OperationallyVerified = $true
                }
                CPM = @{
                    Passed = $true
                    OperationallyVerified = $false
                }
            }
        }
    }
    AfterAll { Remove-Variable -Name PAeasyHealthFixture -Scope Global -ErrorAction SilentlyContinue }

    It 'reports a service-only probe as NotTested without opening a session' {
        $r = InModuleScope PASeasyInstall { Test-PASDeploymentStatus -Config test.json }
        $r.Mode | Should -BeExactly ServiceOnly
        $r.OperationallyVerified | Should -BeFalse
        @($r.Components | Where-Object OperationallyVerified).Count | Should -Be 0
        $r.Components.FunctionalVerification | Select-Object -Unique | Should -BeExactly NotTested
        Should -Invoke Enter-PASVaultLock -ModuleName PASeasyInstall -Times 0
        Should -Invoke Invoke-PASAuthenticatedWebHealth -ModuleName PASeasyInstall -Times 0
    }
    It 'holds the Vault lock while the session is open and releases it afterwards' {
        $r = InModuleScope PASeasyInstall -Parameters @{ C = $credential } {
            param($C)
            Test-PASDeploymentStatus -Config test.json -VaultCredential $C -ControlledCPMAccountId 32_3
        }
        @($global:PAeasyHealthFixture.Events) | Should -Be @('lock:vault.alias', 'authenticate', 'unlock')
        $r.Mode | Should -BeExactly AuthenticatedAPI
        $r.OperationallyVerified | Should -BeFalse
        ($r.Components | Where-Object Type -eq PVWA).OperationallyVerified | Should -BeTrue
        ($r.Components | Where-Object Type -eq CPM).OperationallyVerified | Should -BeFalse
        ($r.Components | Where-Object Type -eq CPM).FunctionalVerification | Should -BeExactly ControlledAccountStatusOnly
        ($r.Components | Where-Object Type -eq PSM).FunctionalVerification | Should -BeExactly NotTested
        Should -Invoke Invoke-PASAuthenticatedWebHealth -ModuleName PASeasyInstall -Times 1 -ParameterFilter { $ApiBaseUri.AbsoluteUri -eq 'https://pvwa.test/PasswordVault/API' }
        ($r | ConvertTo-Json -Depth 10) | Should -Not -Match SYNTHETIC_PUBLIC_HEALTH_SECRET
    }
    It 'does not open a session when the Vault lock cannot be taken' {
        Mock Enter-PASVaultLock -ModuleName PASeasyInstall { throw 'Vault vault.alias is in use by another PASeasyInstall controller' }
        $r = InModuleScope PASeasyInstall -Parameters @{ C = $credential } { param($C) Test-PASDeploymentStatus -Config test.json -VaultCredential $C }
        $r.FailureCode | Should -BeExactly HealthNotStarted
        $r.Message | Should -Match 'in use by another'
        Should -Invoke Invoke-PASAuthenticatedWebHealth -ModuleName PASeasyInstall -Times 0
    }
    It 'releases the Vault lock when the health helper throws' {
        Mock Invoke-PASAuthenticatedWebHealth -ModuleName PASeasyInstall { throw 'synthetic helper failure' }
        $r = InModuleScope PASeasyInstall -Parameters @{ C = $credential } { param($C) Test-PASDeploymentStatus -Config test.json -VaultCredential $C }
        $r.FailureCode | Should -BeExactly AuthenticatedHealthFailed
        $global:PAeasyHealthFixture.Held | Should -BeFalse
        ($r | ConvertTo-Json -Depth 10) | Should -Not -Match SYNTHETIC_PUBLIC_HEALTH_SECRET
    }
    It 'requires an explicit URL if no PVWA URL is configured and refuses HTTP' {
        Mock Read-PASConfiguration -ModuleName PASeasyInstall { @{
                vault = @{ address = 'vault.alias' }
                components = @(@{
                        id = 'pvwa'
                        type = 'PVWA'
                        options = @{}
                    })
            } }
        $first = InModuleScope PASeasyInstall -Parameters @{ C = $credential } { param($C) Test-PASDeploymentStatus -Config test.json -VaultCredential $C }
        $first.FailureCode | Should -BeExactly ExplicitApiBaseUriRequired
        $second = InModuleScope PASeasyInstall -Parameters @{ C = $credential } { param($C) Test-PASDeploymentStatus -Config test.json -VaultCredential $C -ApiBaseUri http://pvwa.test/API }
        $second.FailureCode | Should -BeExactly InvalidHTTPSApiEndpoint
        Should -Invoke Enter-PASVaultLock -ModuleName PASeasyInstall -Times 0
        Should -Invoke Invoke-PASAuthenticatedWebHealth -ModuleName PASeasyInstall -Times 0
    }
    It 'reports the failure code of a session that could not be closed' {
        Mock Invoke-PASAuthenticatedWebHealth -ModuleName PASeasyInstall {
            [pscustomobject]@{
                SessionState = 'Unknown'
                FailureCode = 'LogoffFailed'
                PVWA = @{
                    Passed = $false
                    OperationallyVerified = $false
                }
                CPM = $null
            }
        }
        $r = InModuleScope PASeasyInstall -Parameters @{ C = $credential } { param($C) Test-PASDeploymentStatus -Config test.json -VaultCredential $C }
        $r.FailureCode | Should -BeExactly LogoffFailed
        ($r.Components | Where-Object Type -eq PVWA).FunctionalVerification | Should -BeExactly Failed
        $global:PAeasyHealthFixture.Held | Should -BeFalse
    }
}
