BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
}
Describe 'Linux checks use the protected durable adapter' {
    BeforeEach {
        $task = Join-Path $TestDrive 'check.sh'
        [IO.File]::WriteAllText($task, "#!/bin/bash`necho checked`n")
        Mock Initialize-PASLinuxDetached -ModuleName PASeasyInstall { [pscustomobject]@{AttemptId = $AttemptId } }
        Mock Wait-PASDetached -ModuleName PASeasyInstall { @{state = 'Succeeded'; exitCode = 0 } }
        Mock Invoke-PASLinuxControl -ModuleName PASeasyInstall { 'PAEASY_RESULT:{"Passed":true,"Evidence":["synthetic transport fixture"]}' }
        Mock Finish-PASLinuxDetached -ModuleName PASeasyInstall {}
        Mock New-Item -ModuleName PASeasyInstall { throw 'Unexpected local controller staging' }
        Mock Copy-PASRawSSH -ModuleName PASeasyInstall { throw 'Unexpected relative SCP path' }
    }
    It 'preserves the journal attempt ID and timeout and parses a bounded independent check result' {
        $r = & (Get-Module PASeasyInstall) {
            param($path)
            Invoke-PASAdapterScript -Target @{
                Protocol = 'SSH'
                Runtime = 'Bash'
                User = 'root'
            } -Credentials @{} -ScriptPath $path -Parameters @{Password = 'SYNTHETIC_STDIN_ONLY' } -TimeoutSeconds 45 -AttemptId ('b' * 32)
        } $task
        $r.Ok | Should -BeTrue
        $r.Terminal.Passed | Should -BeTrue
        $r.AttemptId | Should -BeExactly ('b' * 32)
        Should -Invoke Initialize-PASLinuxDetached -ModuleName PASeasyInstall -Times 1 -ParameterFilter { $AttemptId -eq ('b' * 32) -and $TimeoutSeconds -eq 45 -and $Parameters.Password -eq 'SYNTHETIC_STDIN_ONLY' }
        Should -Invoke Wait-PASDetached -ModuleName PASeasyInstall -Times 1 -ParameterFilter { $AttemptId -eq ('b' * 32) }
        Should -Invoke Copy-PASRawSSH -ModuleName PASeasyInstall -Times 0
        Should -Invoke New-Item -ModuleName PASeasyInstall -Times 0
    }
    It 'keeps an interrupted attempt unknown instead of returning a clean failure or replaying it' {
        Mock Wait-PASDetached -ModuleName PASeasyInstall { @{state = 'Interrupted' } }
        { & (Get-Module PASeasyInstall) { param($p) Invoke-PASAdapterScript @{
                    Protocol = 'SSH'
                    Runtime = 'Bash'
                    User = 'root'
                } @{} $p @{} } $task } |
            Should -Throw '*PAExecUnknown*'
        Should -Invoke Initialize-PASLinuxDetached -ModuleName PASeasyInstall -Times 1
        Should -Invoke Finish-PASLinuxDetached -ModuleName PASeasyInstall -Times 0
    }
    It 'refuses changed script bytes and unsupported Windows SSH before staging any input' {
        { & (Get-Module PASeasyInstall) { param($p) Invoke-PASRawSSHScript @{Runtime = 'Bash' } $p 'changed' @{} Object } $task } |
            Should -Throw '*source changed*'
        { & (Get-Module PASeasyInstall) { param($p) Invoke-PASRawSSHScript @{Runtime = 'WindowsPowerShell' } $p 'changed' @{} Object } $task } |
            Should -Throw '*native WinRM*'
        Should -Invoke Initialize-PASLinuxDetached -ModuleName PASeasyInstall -Times 0
    }
}
