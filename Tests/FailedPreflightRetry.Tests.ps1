BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
}
Describe 'Explicit known-failed Linux preflight retry admission' {
    InModuleScope PASeasyInstall {
        BeforeEach {
            $script:retryState = @{digest = 'unchanged'; steps = @{preflight = @{status = 'Unknown'; attemptId = ('c' * 32) } } }
            $script:retryPlan = [pscustomobject]@{
                Digest = 'unchanged'
                Runtime = 'Bash'
                Target = @{
                    Protocol = 'SSH'
                    Runtime = 'Bash'
                }
                Steps = @(@{
                        Id = 'preflight'
                        Inputs = @{Stage = 'Preflight' }
                    })
            }
            Mock Read-PASJournal { $script:retryState }
            Mock Get-PASWorkflowPlan { $script:retryPlan }
            Mock Get-PASDetachedStatus { @{state = 'Failed'; attemptId = ('c' * 32); workerActive = $false } }
        }
        It 'requires actual failure and worker exit even when the local observation was unknown' {
            $r = @(Get-PASFailedPreflightRetry -WorkflowPath fixture -InventoryPath fixture -StatePath fixture)
            $r.Count | Should -Be 1
            $r[0] | Should -BeExactly preflight
            $script:retryState.steps.preflight.status | Should -BeExactly Unknown
            $script:retryState.steps.preflight.attemptId | Should -BeExactly ('c' * 32)
        }
        It 'refuses an active worker, missing exit evidence, another attempt or an uncertain result' {
            foreach ($case in @(@{
                        state = 'Failed'
                        attemptId = ('c' * 32)
                        workerActive = $true
                    }, @{
                        state = 'Failed'
                        attemptId = ('c' * 32)
                    }, @{
                        state = 'Failed'
                        attemptId = ('d' * 32)
                        workerActive = $false
                    }, @{
                        state = 'Unknown'
                        attemptId = ('c' * 32)
                        workerActive = $false
                    })) {
                $script:remoteRetryFixture = $case
                Mock Get-PASDetachedStatus { $script:remoteRetryFixture }
                { Get-PASFailedPreflightRetry -WorkflowPath fixture -InventoryPath fixture -StatePath fixture } |
                    Should -Throw '*same known-failed attempt*'
            }
        }
        It 'refuses changed workflow or payload identity before contacting the target' {
            $script:retryPlan.Digest = 'changed'
            { Get-PASFailedPreflightRetry -WorkflowPath fixture -InventoryPath fixture -StatePath fixture } | Should -Throw '*changed workflow*'
            Should -Invoke Get-PASDetachedStatus -Times 0
        }
        It 'cannot authorize an install action disguised with the preflight ID' {
            $script:retryPlan.Steps[0].Inputs.Stage = 'Install'
            { Get-PASFailedPreflightRetry -WorkflowPath fixture -InventoryPath fixture -StatePath fixture } | Should -Throw '*fixed Linux preflight*'
            Should -Invoke Get-PASDetachedStatus -Times 0
        }
        It 'does not retry a successful preflight' {
            $script:retryState.steps.preflight.status = 'Succeeded'
            @(Get-PASFailedPreflightRetry -WorkflowPath fixture -InventoryPath fixture -StatePath fixture).Count | Should -Be 0
            Should -Invoke Get-PASDetachedStatus -Times 0
        }
    }
    It 'exposes an explicit preflight option while retaining refusal of blind unknown retries' {
        (Get-Command Resume-PASRun).Parameters.ContainsKey('RetryFailedPreflight') | Should -BeTrue
        (Get-Command Resume-PASRun).Parameters.ContainsKey('RetryStep') | Should -BeTrue
        (Get-Command Resume-PASRun).Parameters.ContainsKey('AllowUnknownRetry') | Should -BeFalse
        InModuleScope PASeasyInstall -Parameters @{Root = $TestDrive } {
            param($Root)
            (Get-Command Resume-PASDeployment).Parameters.ContainsKey('RetryFailedPreflight') | Should -BeTrue
            { Resume-PASDeployment -RunId ('a' * 32) -DataRoot $Root -AllowUnknownRetry } | Should -Throw
        }
    }
}
