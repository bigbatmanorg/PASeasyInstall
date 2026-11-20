BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1'); Import-PASTestModule
}
Describe 'Vendor-directed reboot checkpoints' {
    It 'requires explicit Boolean evidence before skipping a reboot' {
        & (Get-Module PASeasyInstall) {
            Test-PASRebootRequired @{RebootRequiredFrom='install'} @{install=@{RebootRequired=$false}} | Should -BeFalse
            Test-PASRebootRequired @{RebootRequiredFrom='install'} @{install=@{RebootRequired=$true}} | Should -BeTrue
            {Test-PASRebootRequired @{RebootRequiredFrom='install'} @{}} | Should -Throw '*missing*'
            {Test-PASRebootRequired @{RebootRequiredFrom='install'} @{install=@{RebootRequired='false'}}} | Should -Throw '*Boolean*'
        }
    }
    It 'refuses to trust a claimed completed reboot without changed boot IDs' {
        & (Get-Module PASeasyInstall) {
            { Test-PASStepCompleted -Step @{} -Kind Reboot -Outputs @{} -Current @{bootBefore='boot1';bootAfter='boot1'} } | Should -Throw '*changed boot identifier*'
            Test-PASStepCompleted -Step @{} -Kind Reboot -Outputs @{} -Current @{bootBefore='boot1';bootAfter='boot2'} | Should -Match 'changed'
        }
    }
    It 'recovers reboot evidence only from the exact completed attempt' {
        & (Get-Module PASeasyInstall) {
            $id=[guid]::NewGuid().ToString('N')
            $remote=@{attemptId=$id;state='Succeeded';data=@{RebootRequired=$true}}
            (Get-PASCompletedAttemptData $remote $id -RequireRebootEvidence).RebootRequired | Should -BeTrue
            {Get-PASCompletedAttemptData $remote 'other' -RequireRebootEvidence} | Should -Throw '*same completed attempt*'
            $remote.state='Running'
            {Get-PASCompletedAttemptData $remote $id -RequireRebootEvidence} | Should -Throw '*same completed attempt*'
        }
    }

    It 'uses only the same succeeded predecessor attempt to observe an already completed reboot' {
        & (Get-Module PASeasyInstall) {
            $id=[guid]::NewGuid().ToString('N')
            $state=@{steps=@{install=@{status='Succeeded';attemptId=$id;remote=@{state='Succeeded';attemptId=$id;bootUtc='2026-11-16T00:00:00Z'}}}}
            Get-PASPriorAttemptBoot @{RebootFromAttempt='install'} $state | Should -Be '2026-11-16T00:00:00Z'
            $state.steps.install.remote.attemptId='other'
            {Get-PASPriorAttemptBoot @{RebootFromAttempt='install'} $state} | Should -Throw '*same completed attempt*'
        }
    }

}
