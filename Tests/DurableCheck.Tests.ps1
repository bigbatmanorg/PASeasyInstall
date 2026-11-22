BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
}
Describe 'Typed independent check task transport' {
    BeforeAll {
        $hostPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall/Private/Engine/Assets/TaskHost.ps1'
        $savedTemp = $env:TEMP
        if (-not $env:TEMP) { $env:TEMP = [IO.Path]::GetTempPath() }
    }
    AfterAll { $env:TEMP = $savedTemp }
    It 'keeps an actual false check distinct from a failed process and redacts secret evidence' {
        $result = & $hostPath -Contract Check -Parameters @{AdminPassword = 'synthetic-check-marker-941' } -Code 'param($AdminPassword) [pscustomobject]@{Passed=$false;Evidence=@($AdminPassword);Message=$AdminPassword;SessionClosed=$true}'
        $result.Ok | Should -BeTrue
        $result.Check.passed | Should -BeFalse
        $result.Check.sessionClosed | Should -BeTrue
        ($result | ConvertTo-Json -Depth 15 -Compress) | Should -Not -Match 'synthetic-check-marker-941'
        $result.Check.evidence[0] | Should -BeExactly '[REDACTED]'
    }
    It 'refuses missing or string acceptance flags and unbounded evidence' {
        foreach ($code in @('[pscustomobject]@{Message="missing"}', '[pscustomobject]@{Passed="false"}', '[pscustomobject]@{Passed=$true;SessionClosed="True"}', '[pscustomobject]@{Passed=$true;Evidence=@(("x"*2049))}', '[pscustomobject]@{Passed=$true;Evidence=@(1..33|ForEach-Object {"entry"})}')) {
            $result = & $hostPath -Contract Check -Parameters @{} -Code $code
            $result.Ok | Should -BeFalse
        }
    }
    It 'does not turn a structured result followed by a nonzero native exit into success' {
        foreach ($contract in @('Object', 'Check')) {
            $result = & $hostPath -Contract $contract -Parameters @{} -Code '[pscustomobject]@{Changed=$false;Passed=$true}; exit 9'
            $result.Ok | Should -BeFalse
            $result.ExitCode | Should -Be 9
        }
    }
}
Describe 'Durable verifier attempt generations' {
    InModuleScope PASeasyInstall {
        BeforeEach {
            $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item $base -ItemType Directory | Out-Null
            [IO.File]::WriteAllText((Join-Path $base 'verify.ps1'), 'param($AdminPassword) [pscustomobject]@{Passed=$true;SessionClosed=$true;Evidence=@()}')
            $plan = [pscustomobject]@{
                Root = $base
                Target = @{
                    Protocol = 'WinRM'
                    Runtime = 'WindowsPowerShell'
                    ComputerName = '192.0.2.18'
                }
            }
            $step = @{Id = 'health'; Verify = 'verify.ps1'; VerifyMode = 'Detached'; VerifyRequiresVaultSession = $true }
            $current = @{status = 'Verifying'; actionAcknowledged = $true }
            $context = @{
                RunDirectory = $base
                State = @{steps = @{health = $current } }
                Redactions = @('synthetic-check-password')
                VaultLocked = $true
                Seq = 0
                Echo = $false
                RunId = 'check001'
                TargetName = 'fixture'
            }
            $script:CheckFixture = @{
                Events = [Collections.Generic.List[string]]::new()
                FailStage = $false
                RemoteState = 'Succeeded'
                Passed = $true
                Closed = $true
                Active = $false
            }
            Mock Finish-PASDetached {}
            Mock Initialize-PASDetached {
                param($Target, $Credentials, $ScriptPath, $Parameters, $AttemptId, $TimeoutSeconds, $Contract)
                $journal = Read-PASJournal (Join-Path $context.RunDirectory 'state.json')
                $journal.steps.health.check.attemptId | Should -BeExactly $AttemptId
                $journal.steps.health.check.status | Should -BeExactly Dispatched
                $Contract | Should -BeExactly Check
                $Parameters.Keys | Should -Not -Contain UnusedSecret
                $script:CheckFixture.Events.Add('Initialize:' + $AttemptId)
                if ($script:CheckFixture.FailStage) { throw 'injected initializer observation loss' }
            }
            Mock Wait-PASDetached {
                param($Target, $Credentials, $AttemptId)
                $script:CheckFixture.Events.Add('Observe:' + $AttemptId)
                return @{
                    state = $script:CheckFixture.RemoteState
                    attemptId = $AttemptId
                    check = @{
                        schemaVersion = 1
                        passed = $script:CheckFixture.Passed
                        sessionClosed = $script:CheckFixture.Closed
                        message = 'checked'
                        evidence = @('identity and logout checked')
                    }
                }
            }
            Mock Wait-PASDetachedSessionQuiescence {
                param($Target, $Credentials, $AttemptId)
                $script:CheckFixture.Events.Add('Quiescent:' + $AttemptId)
                if ($script:CheckFixture.Active) { throw 'PAExecUnknown: worker exit unconfirmed' }
            }
        }
        It 'journals before dispatch and reconciles an unconsumed success without another launch' {
            $result = Get-PASDurableCheck $plan $step @{} @{
                AdminPassword = 'synthetic-check-password'
                UnusedSecret = 'not required'
            } $current $context
            $result.Passed | Should -BeTrue
            $id = $current.check.attemptId
            $current.check.consumed | Should -BeFalse
            # Simulate controller loss after remote completion but before parent consumption.
            $context.State = Read-PASJournal (Join-Path $base 'state.json')
            $current = $context.State.steps.health
            (Get-PASDurableCheck $plan $step @{} @{} $current $context).Passed | Should -BeTrue
            $current.check.attemptId | Should -BeExactly $id
            Should -Invoke Initialize-PASDetached -Times 1 -Exactly
            Complete-PASCheckGeneration $current
            $current.status = 'Succeeded'
            Save-PASState $context
            $context.State = Read-PASJournal (Join-Path $base 'state.json')
            $current = $context.State.steps.health
            $null = Get-PASDurableCheck $plan $step @{} @{} $current $context Revalidation
            $current.check.attemptId | Should -Not -Be $id
            $current.check.previousAttempts | Should -Contain $id
            Should -Invoke Initialize-PASDetached -Times 2 -Exactly
        }
        It 'retains the original dispatch ID after interrupted staging and missing target evidence' {
            $script:CheckFixture.FailStage = $true
            { Get-PASDurableCheck $plan $step @{} @{} $current $context } | Should -Throw '*staging interrupted*'
            $id = $current.check.attemptId
            $context.State = Read-PASJournal (Join-Path $base 'state.json')
            $current = $context.State.steps.health
            $script:CheckFixture.RemoteState = 'Missing'
            { Get-PASDurableCheck $plan $step @{} @{} $current $context } | Should -Throw '*same attempt*'
            $current.check.attemptId | Should -BeExactly $id
            $current.check.consumed | Should -BeFalse
            Should -Invoke Initialize-PASDetached -Times 1 -Exactly
        }
        It 'requires worker exit and typed session closure before accepting any authenticated result' {
            $script:CheckFixture.Active = $true
            { Get-PASDurableCheck $plan $step @{} @{} $current $context } | Should -Throw '*worker exit*'
            $script:CheckFixture.Active = $false
            $script:CheckFixture.Closed = 'True'
            { Get-PASDurableCheck $plan $step @{} @{} $current $context } | Should -Throw '*session closure*'
            $current.check.consumed | Should -BeFalse
            Should -Invoke Initialize-PASDetached -Times 1 -Exactly
        }
        It 'refuses an unauthorised verifier before staging and preserves helper drift as uncertainty' {
            $context.VaultLocked = $false
            { Get-PASDurableCheck $plan $step @{} @{} $current $context } | Should -Throw '*without the Vault lock*'
            Should -Invoke Initialize-PASDetached -Times 0
            $context.VaultLocked = $true
            $null = Get-PASDurableCheck $plan $step @{} @{} $current $context
            [IO.File]::AppendAllText((Join-Path $base 'verify.ps1'), ' # changed')
            { Get-PASDurableCheck $plan $step @{} @{} $current $context } | Should -Throw '*script changed*'
            Should -Invoke Initialize-PASDetached -Times 1 -Exactly
        }
        It 'waits for the authenticated action worker before starting an independent verifier' {
            $step.RequiresVaultSession = $true
            $current.attemptId = '0123456789abcdef0123456789abcdef'
            $null = Get-PASStepCheck -Plan $plan -Step $step -Credentials @{} -Inputs @{} -Current $current -Context $context -Script verify.ps1
            $script:CheckFixture.Events[0] | Should -BeExactly ('Quiescent:' + $current.attemptId)
            $script:CheckFixture.Events[1] | Should -Match '^Initialize:'
        }
    }
}
Describe 'Engine durable verifier recovery without action replay' {
    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $base -ItemType Directory | Out-Null
        $wf = Join-Path $base 'workflow.psd1'
        $inv = Join-Path $base 'inventory.psd1'
        $state = Join-Path $base 'Runs'
        [IO.File]::WriteAllText((Join-Path $base 'task.ps1'), 'param(); [pscustomobject]@{Changed=$false}')
        [IO.File]::WriteAllText((Join-Path $base 'verify.ps1'), 'param(); [pscustomobject]@{Passed=$true;SessionClosed=$true}')
        [IO.File]::WriteAllText($wf, "@{SchemaVersion=1;Name='fixture';Target='fixture';Steps=@(@{Id='install';Script='task.ps1';Verify='verify.ps1';VerifyMode='Detached';VerifyRequiresVaultSession=`$true;TimeoutSeconds=23})}")
        [IO.File]::WriteAllText($inv, "@{SchemaVersion=1;Targets=@{fixture=@{Protocol='WinRM';Runtime='WindowsPowerShell';ComputerName='192.0.2.18'}}}")
        $global:PAEasyDurableEngine = @{
            Passed = $false
            FailObserve = $false
            ActionCount = 0
            CheckIds = [Collections.Generic.List[string]]::new()
            Timeouts = [Collections.Generic.List[int]]::new()
            Locks = 0
            Releases = 0
        }
        Mock Invoke-PASRemoteLock -ModuleName PASeasyInstall { $false }
        Mock Clear-PASConnections -ModuleName PASeasyInstall {}
        Mock Clear-PASRecoveryTasks -ModuleName PASeasyInstall {}
        Mock Finish-PASDetached -ModuleName PASeasyInstall {}
        Mock Wait-PASDetachedSessionQuiescence -ModuleName PASeasyInstall {}
        Mock Enter-PASVaultLock -ModuleName PASeasyInstall {
            $global:PAEasyDurableEngine.Locks++
            return [pscustomobject]@{Address = $Address }
        }
        Mock Exit-PASVaultLock -ModuleName PASeasyInstall { if ($null -ne $Lock) { $global:PAEasyDurableEngine.Releases++ } }
        Mock Invoke-PASAdapterScript -ModuleName PASeasyInstall {
            $global:PAEasyDurableEngine.ActionCount++
            return @{
                Ok = $true
                Terminal = @{Changed = $false }
                Output = ''
            }
        }
        Mock Initialize-PASDetached -ModuleName PASeasyInstall {
            param(
                $AttemptId,
                $TimeoutSeconds
            ) $global:PAEasyDurableEngine.CheckIds.Add($AttemptId)
            $global:PAEasyDurableEngine.Timeouts.Add($TimeoutSeconds)
        }
        Mock Wait-PASDetached -ModuleName PASeasyInstall {
            param(
                $AttemptId,
                $TimeoutSeconds
            ) $global:PAEasyDurableEngine.Timeouts.Add($TimeoutSeconds)
            if ($global:PAEasyDurableEngine.FailObserve) { throw 'fixture observation loss' }
            return @{
                state = 'Succeeded'
                attemptId = $AttemptId
                check = @{
                    schemaVersion = 1
                    passed = $global:PAEasyDurableEngine.Passed
                    sessionClosed = $true
                    evidence = @()
                    message = 'independent check'
                }
            }
        }
    }
    AfterEach { Remove-Variable PAEasyDurableEngine -Scope Global -ErrorAction SilentlyContinue }
    It 'commits a negative check with the acknowledged action, then only reruns independent verification' {
        { & (Get-Module PASeasyInstall) { param(
                    $w,
                    $i,
                    $s
                ) Invoke-PASWorkflow $w $i -StateRoot $s -RunId durable001 -VaultAddress 192.0.2.99 -Quiet } $wf $inv $state } |
            Should -Throw '*Verification failed*'
        $journal = Get-Content (Join-Path $state 'durable001/fixture/state.json') -Raw | ConvertFrom-Json
        $journal.steps.install.actionAcknowledged | Should -BeTrue
        $journal.steps.install.status | Should -BeExactly Failed
        $journal.steps.install.message | Should -Match 'Verification failed'
        $journal.steps.install.check.consumed | Should -BeTrue
        $actionId = $journal.steps.install.attemptId
        $oldCheck = $journal.steps.install.check.attemptId
        # The Vault lock is never kept after a failed step.
        $global:PAEasyDurableEngine.Releases | Should -Be $global:PAEasyDurableEngine.Locks
        $global:PAEasyDurableEngine.Passed = $true
        $result = & (Get-Module PASeasyInstall) { param(
                $w,
                $i,
                $s
            ) Invoke-PASWorkflow $w $i -StateRoot $s -RunId durable001 -VaultAddress 192.0.2.99 -Resume -Quiet } $wf $inv $state
        $result.Status | Should -BeExactly Succeeded
        $global:PAEasyDurableEngine.ActionCount | Should -Be 1
        $journal = Get-Content (Join-Path $state 'durable001/fixture/state.json') -Raw | ConvertFrom-Json
        $journal.steps.install.attemptId | Should -BeExactly $actionId
        # The step succeeded after the resume: the error text of the first try is gone.
        $journal.steps.install.status | Should -BeExactly Succeeded
        [string]$journal.steps.install.message | Should -Not -Match 'failed'
        $journal.steps.install.check.attemptId | Should -Not -Be $oldCheck
        $global:PAEasyDurableEngine.Releases | Should -Be $global:PAEasyDurableEngine.Locks
        $null = & (Get-Module PASeasyInstall) { param(
                $w,
                $i,
                $s
            ) Invoke-PASWorkflow $w $i -StateRoot $s -RunId durable001 -VaultAddress 192.0.2.99 -Resume -Quiet } $wf $inv $state
        $global:PAEasyDurableEngine.ActionCount | Should -Be 1
        @($global:PAEasyDurableEngine.Timeouts) | Should -Be @(23, 23, 23, 23, 23, 23)
    }
    It 'does not let explicit Retry bypass an outstanding verifier and relaunch its action' {
        $global:PAEasyDurableEngine.FailObserve = $true
        { & (Get-Module PASeasyInstall) { param(
                    $w,
                    $i,
                    $s
                ) Invoke-PASWorkflow $w $i -StateRoot $s -RunId durable002 -VaultAddress 192.0.2.99 -Quiet } $wf $inv $state } |
            Should -Throw '*observation loss*'
        $before = Get-Content (Join-Path $state 'durable002/fixture/state.json') -Raw | ConvertFrom-Json
        { & (Get-Module PASeasyInstall) { param(
                    $w,
                    $i,
                    $s
                ) Invoke-PASWorkflow $w $i -StateRoot $s -RunId durable002 -VaultAddress 192.0.2.99 -Resume -Retry install -Quiet } $wf $inv $state } |
            Should -Throw '*unconsumed durable verifier*'
        $after = Get-Content (Join-Path $state 'durable002/fixture/state.json') -Raw | ConvertFrom-Json
        $after.steps.install.check.attemptId | Should -BeExactly $before.steps.install.check.attemptId
        $global:PAEasyDurableEngine.ActionCount | Should -Be 1
        $global:PAEasyDurableEngine.CheckIds.Count | Should -Be 1
    }
    It 'rejects a skipping probe on an authenticated action before dispatch' {
        [IO.File]::WriteAllText($wf, "@{SchemaVersion=1;Name='unsafe';Target='fixture';Steps=@(@{Id='register';Script='task.ps1';Mode='Detached';RequiresVaultSession=`$true;Verify='verify.ps1';Probe='verify.ps1'})}")
        { & (Get-Module PASeasyInstall) { param(
                    $w,
                    $i
                ) Get-PASWorkflowPlan $w $i } $wf $inv } |
            Should -Throw '*cannot use a skipping direct probe*'
        $global:PAEasyDurableEngine.ActionCount | Should -Be 0
        $global:PAEasyDurableEngine.CheckIds.Count | Should -Be 0
    }
}
