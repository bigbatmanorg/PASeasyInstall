BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Vendor-directed reboot checkpoints' {
    It 'requires explicit Boolean evidence before skipping a reboot' {
        & (Get-Module PASeasyInstall.Core) {
            Test-PAExecRebootRequired @{RebootRequiredFrom='install'} @{install=@{RebootRequired=$false}} | Should -BeFalse
            Test-PAExecRebootRequired @{RebootRequiredFrom='install'} @{install=@{RebootRequired=$true}} | Should -BeTrue
            {Test-PAExecRebootRequired @{RebootRequiredFrom='install'} @{}} | Should -Throw '*missing*'
            {Test-PAExecRebootRequired @{RebootRequiredFrom='install'} @{install=@{RebootRequired='false'}}} | Should -Throw '*Boolean*'
        }
    }
    It 'refuses to trust a claimed completed reboot without changed boot IDs' {
        & (Get-Module PASeasyInstall.Core) {
            { Test-PAExecStepCompleted -Step @{} -Kind Reboot -Outputs @{} -Current @{bootBefore='boot1';bootAfter='boot1'} } | Should -Throw '*changed boot identifier*'
            Test-PAExecStepCompleted -Step @{} -Kind Reboot -Outputs @{} -Current @{bootBefore='boot1';bootAfter='boot2'} | Should -Match 'changed'
        }
    }
    It 'recovers reboot evidence only from the exact completed attempt' {
        & (Get-Module PASeasyInstall.Core) {
            $id=[guid]::NewGuid().ToString('N')
            $remote=@{attemptId=$id;state='Succeeded';data=@{RebootRequired=$true}}
            (Get-PAExecCompletedAttemptData $remote $id -RequireRebootEvidence).RebootRequired | Should -BeTrue
            {Get-PAExecCompletedAttemptData $remote 'other' -RequireRebootEvidence} | Should -Throw '*same completed attempt*'
            $remote.state='Running'
            {Get-PAExecCompletedAttemptData $remote $id -RequireRebootEvidence} | Should -Throw '*same completed attempt*'
        }
    }

    It 'uses only the same succeeded predecessor attempt to observe an already completed reboot' {
        & (Get-Module PASeasyInstall.Core) {
            $id=[guid]::NewGuid().ToString('N')
            $state=@{steps=@{install=@{status='Succeeded';attemptId=$id;remote=@{state='Succeeded';attemptId=$id;bootUtc='2026-11-16T00:00:00Z'}}}}
            Get-PAExecPriorAttemptBoot @{RebootFromAttempt='install'} $state | Should -Be '2026-11-16T00:00:00Z'
            $state.steps.install.remote.attemptId='other'
            {Get-PAExecPriorAttemptBoot @{RebootFromAttempt='install'} $state} | Should -Throw '*same completed attempt*'
        }
    }

}
