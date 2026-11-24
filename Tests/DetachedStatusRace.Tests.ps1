# A Windows worker writes its final status and then ends. The status probe reads the status file first and looks
# at the process after: a worker that ends between the two must be reported with its final status, not as
# Interrupted (lab 2026-11-24: a PSM step that had succeeded ended the run as Unknown).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
}

Describe 'Status of a detached Windows step whose worker ends while it is looked at' -Skip:($env:OS -ne 'Windows_NT') {
    It 'reports the final status the worker wrote, not Interrupted' {
        InModuleScope PASeasyInstall {
            $attempt = 'a1b2c3d4e5f60718293a4b5c6d7e8f90'
            $stage = Join-Path $TestDrive 'stage'
            $dir = Join-Path (Join-Path $stage 'attempts') $attempt
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            $running = @{ schemaVersion = 2; attemptId = $attempt; pid = 4242; bootUtc = $boot; state = 'Running' }
            $script:statusPath = Join-Path $dir 'status.json'
            $script:finalJson = (@{ schemaVersion = 2; attemptId = $attempt; pid = 4242; bootUtc = $boot; state = 'Succeeded'; message = 'done' } | ConvertTo-Json -Compress)
            Set-Content -LiteralPath $script:statusPath -Value ($running | ConvertTo-Json -Compress)

            Mock Get-PASConnection { New-MockObject -Type System.Management.Automation.Runspaces.PSSession }
            Mock Get-PASAttemptRoot { $dir }
            Mock Invoke-Command { & $ScriptBlock @ArgumentList }
            Mock Get-ScheduledTask { $null }
            # The worker writes its final status and ends exactly when the probe looks for its process.
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Process' } {
                Set-Content -LiteralPath $script:statusPath -Value $script:finalJson
                $null
            }

            $status = Get-PASDetachedStatus -Target @{ Protocol = 'WinRM'; StageRoot = $stage } -Credentials @{} -AttemptId $attempt
            $status.state | Should -Be 'Succeeded'
        }
    }
    It 'still reports Interrupted when the worker is gone and the status file was never finished' {
        InModuleScope PASeasyInstall {
            $attempt = 'b1b2c3d4e5f60718293a4b5c6d7e8f90'
            $stage = Join-Path $TestDrive 'stage2'
            $dir = Join-Path (Join-Path $stage 'attempts') $attempt
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            Set-Content -LiteralPath (Join-Path $dir 'status.json') -Value (@{ schemaVersion = 2; attemptId = $attempt; pid = 4243; bootUtc = $boot; state = 'Running' } | ConvertTo-Json -Compress)

            Mock Get-PASConnection { New-MockObject -Type System.Management.Automation.Runspaces.PSSession }
            Mock Get-PASAttemptRoot { $dir }
            Mock Invoke-Command { & $ScriptBlock @ArgumentList }
            Mock Get-ScheduledTask { $null }
            Mock Get-CimInstance -ParameterFilter { $ClassName -eq 'Win32_Process' } { $null }

            $status = Get-PASDetachedStatus -Target @{ Protocol = 'WinRM'; StageRoot = $stage } -Credentials @{} -AttemptId $attempt
            $status.state | Should -Be 'Interrupted'
        }
    }
}
