BeforeAll {
    function Get-PASDataRoot { 'C:\health-tests' }
    function Read-PASConfiguration {param($Path)}
    function Get-PASResourceIdentity {param($Address)}
    function Enter-PASGate {param($Name,$DataRoot,$RunId,$TimeoutSeconds)}
    function Invoke-PASAuthenticatedWebHealth {param($ApiBaseUri,$Credential,$ControlledCPMAccountId)}
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/Private/V2/Diagnostics.ps1')
    $credential=[pscredential]::new('Administrator',(ConvertTo-SecureString 'SYNTHETIC_PUBLIC_HEALTH_SECRET' -AsPlainText -Force))
}
Describe 'Public deployment health serializes actual API sessions' {
    BeforeEach {
        $script:gates=@();$script:events=@()
        Mock Get-PASComponentStatus {@([pscustomobject]@{Component='pvwa';Type='PVWA';ServiceStatus='Running'},[pscustomobject]@{Component='cpm';Type='CPM';ServiceStatus='Running'},[pscustomobject]@{Component='psm';Type='PSM';ServiceStatus='Running'})}
        Mock Read-PASConfiguration {@{vault=@{address='vault.alias'};components=@(@{id='pvwa';type='PVWA';options=@{pvwaUrl='https://pvwa.test/PasswordVault'}})}}
        Mock Get-PASResourceIdentity {@('192.0.2.12','192.0.2.11','192.0.2.12')}
        Mock Enter-PASGate {
            $script:events+=('gate:'+ $Name)
            $g=[pscustomobject]@{Name=$Name;Completed=$false;Disposed=$false;PreexistingClaim=$false}
            $g|Add-Member ScriptMethod Complete {$this.Completed=$true}
            $g|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
            $script:gates+= $g
            $g
        }
        Mock Invoke-PASAuthenticatedWebHealth {
            $script:events+='authenticate'
            [pscustomobject]@{SessionState='Closed';FailureCode='';PVWA=@{Passed=$true;OperationallyVerified=$true};CPM=@{Passed=$true;OperationallyVerified=$false}}
        }
    }
    It 'preserves explicit service-only NotTested without opening a session' {
        $r=Test-PASDeploymentStatus -Config test.json
        $r.Mode|Should -BeExactly ServiceOnly;$r.OperationallyVerified|Should -BeFalse
        @($r.Components|Where-Object OperationallyVerified).Count|Should -Be 0
        $r.Components.FunctionalVerification|Select-Object -Unique|Should -BeExactly NotTested
        Should -Invoke Enter-PASGate -Times 0
        Should -Invoke Invoke-PASAuthenticatedWebHealth -Times 0
    }
    It 'holds every canonical Vault address before login and closes all claims after logoff' {
        $r=Test-PASDeploymentStatus -Config test.json -VaultCredential $credential -ControlledCPMAccountId 32_3
        $script:events|Should -Be @('gate:vault-192.0.2.11','gate:vault-192.0.2.12','authenticate')
        @($script:gates|Where-Object {-not $_.Completed -or -not $_.Disposed}).Count|Should -Be 0
        $r.ClaimRetained|Should -BeFalse;$r.OperationallyVerified|Should -BeFalse
        ($r.Components|Where-Object Type -eq PVWA).OperationallyVerified|Should -BeTrue
        ($r.Components|Where-Object Type -eq CPM).OperationallyVerified|Should -BeFalse
        ($r.Components|Where-Object Type -eq CPM).FunctionalVerification|Should -BeExactly ControlledAccountStatusOnly
        ($r.Components|Where-Object Type -eq PSM).FunctionalVerification|Should -BeExactly NotTested
        Should -Invoke Invoke-PASAuthenticatedWebHealth -Times 1 -ParameterFilter {$ApiBaseUri.AbsoluteUri -eq 'https://pvwa.test/PasswordVault/API'}
        ($r|ConvertTo-Json -Depth 10)|Should -Not -Match SYNTHETIC_PUBLIC_HEALTH_SECRET
    }
    It 'retains every durable claim and reports run identity after uncertain session cleanup' {
        Mock Invoke-PASAuthenticatedWebHealth {[pscustomobject]@{SessionState='Unknown';FailureCode='LogoffFailed';PVWA=@{Passed=$false;OperationallyVerified=$false};CPM=$null}}
        $id='1'*32
        $r=Test-PASDeploymentStatus -Config test.json -VaultCredential $credential -HealthRunId $id -DataRoot C:\one
        $r.ClaimRetained|Should -BeTrue;$r.HealthRunId|Should -BeExactly $id
        @($script:gates|Where-Object Completed).Count|Should -Be 0
        @($script:gates|Where-Object {-not $_.Disposed}).Count|Should -Be 0
        Should -Invoke Enter-PASGate -Times 2 -ParameterFilter {$RunId -eq $id -and $DataRoot -eq 'C:\one'}
    }
    It 'cleans an acquired partial lock set when another address is blocked before any login' {
        Mock Enter-PASGate {throw 'SYNTHETIC_PUBLIC_HEALTH_SECRET'} -ParameterFilter {$Name -eq 'vault-192.0.2.12'}
        $r=Test-PASDeploymentStatus -Config test.json -VaultCredential $credential
        $r.FailureCode|Should -BeExactly HealthCoordinationFailed
        $r.ClaimRetained|Should -BeFalse;$script:gates[0].Completed|Should -BeTrue
        Should -Invoke Invoke-PASAuthenticatedWebHealth -Times 0
        ($r|ConvertTo-Json -Depth 10)|Should -Not -Match SYNTHETIC_PUBLIC_HEALTH_SECRET
    }
    It 'retains claims when the helper unexpectedly throws after dispatch' {
        Mock Invoke-PASAuthenticatedWebHealth {throw 'SYNTHETIC_PUBLIC_HEALTH_SECRET'}
        $r=Test-PASDeploymentStatus -Config test.json -VaultCredential $credential
        $r.FailureCode|Should -BeExactly AuthenticatedHealthFailed;$r.ClaimRetained|Should -BeTrue
        @($script:gates|Where-Object Completed).Count|Should -Be 0
        ($r|ConvertTo-Json -Depth 10)|Should -Not -Match SYNTHETIC_PUBLIC_HEALTH_SECRET
    }
    It 'requires an explicit URL if no selected PVWA URL is configured and refuses HTTP' {
        Mock Read-PASConfiguration {@{vault=@{address='vault.alias'};components=@(@{id='pvwa';type='PVWA';options=@{}})}}
        (Test-PASDeploymentStatus -Config test.json -VaultCredential $credential).FailureCode|Should -BeExactly ExplicitApiBaseUriRequired
        (Test-PASDeploymentStatus -Config test.json -VaultCredential $credential -ApiBaseUri http://pvwa.test/API).FailureCode|Should -BeExactly InvalidHTTPSApiEndpoint
        Should -Invoke Enter-PASGate -Times 0
        Should -Invoke Invoke-PASAuthenticatedWebHealth -Times 0
    }
    It 'suppresses cleanup exceptions and reports a retained claim conservatively' {
        Mock Enter-PASGate {
            $g=[pscustomobject]@{Completed=$false;PreexistingClaim=$false}
            $g|Add-Member ScriptMethod Complete {$this.Completed=$true}
            $g|Add-Member ScriptMethod Dispose {throw 'SYNTHETIC_PUBLIC_HEALTH_SECRET'}
            $g
        }
        $r=Test-PASDeploymentStatus -Config test.json -VaultCredential $credential
        $r.ClaimRetained|Should -BeTrue;$r.FailureCode|Should -BeExactly HealthGateCleanupFailed
        ($r|ConvertTo-Json -Depth 10)|Should -Not -Match SYNTHETIC_PUBLIC_HEALTH_SECRET
    }
    It 'refuses a new logon when any prior claim exists and preserves only those prior claims' {
        Mock Enter-PASGate {
            $g=[pscustomobject]@{Name=$Name;Completed=$false;Disposed=$false;PreexistingClaim=($Name -eq 'vault-192.0.2.11')}
            $g|Add-Member ScriptMethod Complete {$this.Completed=$true}
            $g|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
            $script:gates+=$g
            $g
        }
        $r=Test-PASDeploymentStatus -Config test.json -VaultCredential $credential -HealthRunId ('1'*32)
        $r.FailureCode|Should -BeExactly HealthSessionReconciliationRequired;$r.ClaimRetained|Should -BeTrue
        ($script:gates|Where-Object PreexistingClaim).Completed|Should -BeFalse
        ($script:gates|Where-Object {-not $_.PreexistingClaim}).Completed|Should -BeTrue
        @($script:gates|Where-Object {-not $_.Disposed}).Count|Should -Be 0
        Should -Invoke Invoke-PASAuthenticatedWebHealth -Times 0
    }
    It 'does not clear a prior unknown claim if another canonical lock cannot be acquired' {
        Mock Enter-PASGate {
            if($Name -eq 'vault-192.0.2.12'){throw 'blocked second lock'}
            $g=[pscustomobject]@{Completed=$false;Disposed=$false;PreexistingClaim=$true}
            $g|Add-Member ScriptMethod Complete {$this.Completed=$true}
            $g|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
            $script:gates+=$g
            $g
        }
        $r=Test-PASDeploymentStatus -Config test.json -VaultCredential $credential -HealthRunId ('1'*32)
        $r.ClaimRetained|Should -BeTrue;$r.FailureCode|Should -BeExactly HealthSessionReconciliationRequired;$script:gates[0].Completed|Should -BeFalse
        $script:gates[0].Disposed|Should -BeTrue
        Should -Invoke Invoke-PASAuthenticatedWebHealth -Times 0
    }
    It 'still disposes mutex handles if completion marking throws' {
        Mock Enter-PASGate {
            $g=[pscustomobject]@{Disposed=$false;PreexistingClaim=$false}
            $g|Add-Member ScriptMethod Complete {throw 'SYNTHETIC_PUBLIC_HEALTH_SECRET'}
            $g|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
            $script:gates+=$g
            $g
        }
        $r=Test-PASDeploymentStatus -Config test.json -VaultCredential $credential
        $r.ClaimRetained|Should -BeTrue;$r.FailureCode|Should -BeExactly HealthGateCleanupFailed
        @($script:gates|Where-Object {-not $_.Disposed}).Count|Should -Be 0
    }
    It 'completes safe NotOpened outcomes without retaining an unnecessary claim' {
        Mock Invoke-PASAuthenticatedWebHealth {[pscustomobject]@{SessionState='NotOpened';FailureCode='MissingCredential';PVWA=@{Passed=$false;OperationallyVerified=$false};CPM=$null}}
        $r=Test-PASDeploymentStatus -Config test.json -VaultCredential $credential
        $r.ClaimRetained|Should -BeFalse
        @($script:gates|Where-Object {-not $_.Completed}).Count|Should -Be 0
    }
}
