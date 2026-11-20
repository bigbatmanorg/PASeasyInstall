BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
}
Describe 'Linux durable transport contracts' {
    It 'rejects attempt path traversal before remote access' {
        & (Get-Module PASeasyInstall) {
            { Get-PASLinuxAttemptRoot '../outside' } | Should -Throw
            { Get-PASLinuxAttemptRoot ('a' * 32 + '/extra') } | Should -Throw
            Get-PASLinuxAttemptRoot ('a' * 32) | Should -Be ('/opt/paeasyinstall/attempts/' + ('a' * 32))
        }
    }
    It 'requires explicitly configured root for durable staging' {
        & (Get-Module PASeasyInstall) {
            { Initialize-PASLinuxDetached @{User = 'ubuntu' } 'none.sh' @{} ('a' * 32) 60 Object } | Should -Throw '*root SSH identity*'
        }
    }
    It 'rejects legacy SCP shell injection and traversal before remote access' {
        & (Get-Module PASeasyInstall) {
            { Copy-PASRawSSH @{Runtime = 'Bash' } 'none' '/opt/paeasyinstall/x;id' } | Should -Throw '*Unsafe Linux SCP path*'
            { Copy-PASRawSSH @{Runtime = 'Bash' } '/opt/paeasyinstall/../outside' 'none' -Download } | Should -Throw '*Unsafe Linux SCP path*'
            { Copy-PASRawSSH @{Runtime = 'Bash' } '/etc/shadow' 'none' -Download } | Should -Throw '*Unsafe Linux SCP path*'
            { Copy-PASRawSSH @{Runtime = 'Bash' } ('/run/paeasyinstall/attempts/' + ('a' * 32) + '/inputs.json') 'none' -Download } |
                Should -Throw '*Unsafe Linux SCP path*'
        }
    }
    It 'refuses the Windows detached executor for an SSH target' {
        & (Get-Module PASeasyInstall) {
            { Assert-PASDetachedSupported @{Protocol = 'SSH'; Runtime = 'Bash' } } | Should -Throw '*requires WinRM transport*'
        }
    }
    It 'retains strict host-key checking' {
        & (Get-Module PASeasyInstall) {
            $args = Get-PASSSHBaseArguments @{KnownHostsFile = 'C:\lab\known_hosts' }
            $args | Should -Contain 'StrictHostKeyChecking=yes'
            $args | Should -Contain 'UserKnownHostsFile=C:\lab\known_hosts'
        }
    }
    It 'rejects command expansion characters in Windows observer paths' -Skip:($env:OS -ne 'Windows_NT') {
        & (Get-Module PASeasyInstall) {
            { Invoke-PASSSHWindowsFileCapture 'ssh.exe' @('-i', 'C:\bad%PATH%\key') 1 } | Should -Throw '*Unsupported character*'
        }
    }
}
