BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Linux checks use the protected durable adapter' {
    BeforeEach {
        $task=Join-Path $TestDrive 'check.sh';[IO.File]::WriteAllText($task,"#!/bin/bash`necho checked`n")
        Mock Initialize-PSLinuxDetached -ModuleName PASeasyInstall.Core {[pscustomobject]@{AttemptId=$AttemptId}}
        Mock Wait-PSDetached -ModuleName PASeasyInstall.Core {@{state='Succeeded';exitCode=0}}
        Mock Invoke-PSLinuxControl -ModuleName PASeasyInstall.Core {'PAEASY_RESULT:{"Passed":true,"Evidence":["synthetic transport fixture"]}'}
        Mock Finish-PSLinuxDetached -ModuleName PASeasyInstall.Core {}
        Mock New-Item -ModuleName PASeasyInstall.Core {throw 'Unexpected local controller staging'}
        Mock Copy-PSRawSSH -ModuleName PASeasyInstall.Core {throw 'Unexpected relative SCP path'}
    }
    It 'preserves the journal attempt ID and timeout and parses a bounded independent check result' {
        $r=& (Get-Module PASeasyInstall.Core) {
            param($path)
            Invoke-PSAdapterScript -Target @{Protocol='SSH';Runtime='Bash';User='root'} -Credentials @{} -ScriptPath $path -Parameters @{Password='SYNTHETIC_STDIN_ONLY'} -TimeoutSeconds 45 -AttemptId ('b'*32)
        } $task
        $r.Ok|Should -BeTrue;$r.Terminal.Passed|Should -BeTrue;$r.AttemptId|Should -BeExactly ('b'*32)
        Should -Invoke Initialize-PSLinuxDetached -ModuleName PASeasyInstall.Core -Times 1 -ParameterFilter {$AttemptId -eq ('b'*32) -and $TimeoutSeconds -eq 45 -and $Parameters.Password -eq 'SYNTHETIC_STDIN_ONLY'}
        Should -Invoke Wait-PSDetached -ModuleName PASeasyInstall.Core -Times 1 -ParameterFilter {$AttemptId -eq ('b'*32)}
        Should -Invoke Copy-PSRawSSH -ModuleName PASeasyInstall.Core -Times 0
        Should -Invoke New-Item -ModuleName PASeasyInstall.Core -Times 0
    }
    It 'keeps an interrupted attempt unknown instead of returning a clean failure or replaying it' {
        Mock Wait-PSDetached -ModuleName PASeasyInstall.Core {@{state='Interrupted'}}
        {& (Get-Module PASeasyInstall.Core) {param($p) Invoke-PSAdapterScript @{Protocol='SSH';Runtime='Bash';User='root'} @{} $p @{} } $task}|Should -Throw '*PAExecUnknown*'
        Should -Invoke Initialize-PSLinuxDetached -ModuleName PASeasyInstall.Core -Times 1
        Should -Invoke Finish-PSLinuxDetached -ModuleName PASeasyInstall.Core -Times 0
    }
    It 'refuses changed script bytes and unsupported Windows SSH before staging any input' {
        {& (Get-Module PASeasyInstall.Core) {param($p) Invoke-PSRawSSHScript @{Runtime='Bash'} $p 'changed' @{} Object} $task}|Should -Throw '*source changed*'
        {& (Get-Module PASeasyInstall.Core) {param($p) Invoke-PSRawSSHScript @{Runtime='WindowsPowerShell'} $p 'changed' @{} Object} $task}|Should -Throw '*native WinRM*'
        Should -Invoke Initialize-PSLinuxDetached -ModuleName PASeasyInstall.Core -Times 0
    }
}
