# Checks are read-only: a transient observation failure (sshd reloading after PSMP hardening) is retried a bounded
# number of times instead of turning the run Unknown; other failures are reported at once.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1'); Import-PASTestModule
}
Describe 'Check evaluation retry' {
    BeforeEach {
        $script:dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); New-Item $script:dir -ItemType Directory | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:dir 'verify.ps1'), 'param() [pscustomobject]@{Passed=$true}')
    }
    It 'retries a timed-out observation and returns the check result' {
        InModuleScope PASeasyInstall -Parameters @{ Dir = $script:dir } {
            param($Dir)
            $script:PSCheckRetryDelaySeconds = 0; $global:PAeasyCheckCalls = 0
            Mock Invoke-PASAdapterScript { $global:PAeasyCheckCalls++; if ($global:PAeasyCheckCalls -lt 3) { throw 'PAExecUnknown: SSH observation timed out; target work was not stopped' }; [pscustomobject]@{ Ok = $true; Terminal = [pscustomobject]@{ Passed = $true } } }
            $r = Get-PASCheck -Plan @{ Root = $Dir; Target = @{ Protocol = 'SSH'; Runtime = 'Bash' } } -Credentials @{} -Script 'verify.ps1' -Inputs @{} -Property 'Passed'
            $r.Passed | Should -BeTrue
            $global:PAeasyCheckCalls | Should -Be 3
        }
    }
    It 'gives up after the bounded attempts' {
        InModuleScope PASeasyInstall -Parameters @{ Dir = $script:dir } {
            param($Dir)
            $script:PSCheckRetryDelaySeconds = 0; $global:PAeasyCheckCalls = 0
            Mock Invoke-PASAdapterScript { $global:PAeasyCheckCalls++; throw 'SSH observation timed out' }
            { Get-PASCheck -Plan @{ Root = $Dir; Target = @{} } -Credentials @{} -Script 'verify.ps1' -Inputs @{} -Property 'Passed' } | Should -Throw "*could not be evaluated*"
            $global:PAeasyCheckCalls | Should -Be $script:PSCheckAttempts
        }
    }
    It 'does not retry other failures' {
        InModuleScope PASeasyInstall -Parameters @{ Dir = $script:dir } {
            param($Dir)
            $script:PSCheckRetryDelaySeconds = 0; $global:PAeasyCheckCalls = 0
            Mock Invoke-PASAdapterScript { $global:PAeasyCheckCalls++; throw 'Permission denied (publickey)' }
            { Get-PASCheck -Plan @{ Root = $Dir; Target = @{} } -Credentials @{} -Script 'verify.ps1' -Inputs @{} -Property 'Passed' } | Should -Throw "*could not be evaluated*"
            $global:PAeasyCheckCalls | Should -Be 1
        }
    }
}
