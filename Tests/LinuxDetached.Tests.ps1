BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Linux durable transport contracts' {
    It 'rejects attempt path traversal before remote access' {
        & (Get-Module PASeasyInstall.Core) {
            {Get-PSLinuxAttemptRoot '../outside'} | Should -Throw
            {Get-PSLinuxAttemptRoot ('a'*32+'/extra')} | Should -Throw
            Get-PSLinuxAttemptRoot ('a'*32) | Should -Be ('/opt/paeasyinstall/attempts/'+('a'*32))
        }
    }
    It 'requires explicitly configured root for durable staging' {
        & (Get-Module PASeasyInstall.Core) {
            {Initialize-PSLinuxDetached @{User='ubuntu'} 'none.sh' @{} ('a'*32) 60 Object} | Should -Throw '*root SSH identity*'
        }
    }
    It 'rejects legacy SCP shell injection and traversal before remote access' {
        & (Get-Module PASeasyInstall.Core) {
            {Copy-PSRawSSH @{Runtime='Bash'} 'none' '/opt/paeasyinstall/x;id'} | Should -Throw '*Unsafe Linux SCP path*'
            {Copy-PSRawSSH @{Runtime='Bash'} '/opt/paeasyinstall/../outside' 'none' -Download} | Should -Throw '*Unsafe Linux SCP path*'
            {Copy-PSRawSSH @{Runtime='Bash'} '/etc/shadow' 'none' -Download} | Should -Throw '*Unsafe Linux SCP path*'
            {Copy-PSRawSSH @{Runtime='Bash'} ('/run/paeasyinstall/attempts/'+('a'*32)+'/inputs.json') 'none' -Download} | Should -Throw '*Unsafe Linux SCP path*'
        }
    }
    It 'supports Bash detached environment while rejecting PowerShell SSH detached' {
        & (Get-Module PASeasyInstall.Core) {
            (Test-PAExecEnvironment -Protocol SSH -Runtime Bash -Detached).Supported | Should -BeTrue
            (Test-PAExecEnvironment -Protocol SSH -Runtime PowerShell -Detached).Supported | Should -BeFalse
        }
    }
    It 'retains strict host-key checking' {
        & (Get-Module PASeasyInstall.Core) {
            $args=Get-PSSSHBaseArguments @{KnownHostsFile='C:\lab\known_hosts'}
            $args | Should -Contain 'StrictHostKeyChecking=yes'
            $args | Should -Contain 'UserKnownHostsFile=C:\lab\known_hosts'
        }
    }
    It 'rejects command expansion characters in Windows observer paths' -Skip:($env:OS -ne 'Windows_NT') {
        & (Get-Module PASeasyInstall.Core) {
            {Invoke-PSSSHWindowsFileCapture 'ssh.exe' @('-i','C:\bad%PATH%\key') 1} | Should -Throw '*Unsupported character*'
        }
    }
}
