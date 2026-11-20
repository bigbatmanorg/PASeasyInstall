BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
}
Describe 'Linux durable attempt directory admission' {
    InModuleScope PASeasyInstall {
        It 'validates every OS-owned ancestor without creating or repairing it' {
            $code = Get-PASLinuxInfrastructureGuard
            foreach ($path in @('/', '/opt', '/run', '/run/systemd', '/run/systemd/system', '/etc', '/etc/systemd', '/etc/systemd/system')) {
                ($code -split ';')[1] |
                    Should -Match ([regex]::Escape($path) + '(?: |$)')
            }
            $code | Should -Match 'test -d'
            $code | Should -Match 'test ! -L'
            $code | Should -Match 'stat -c %u'
            $code | Should -Match '022'
            $code | Should -Not -Match '\b(chmod|mkdir|install|rm|systemctl)\b'
            foreach ($path in @('/opt/../etc', '/run/./tmp', '/opt//x', '/opt/x;id', 'relative')) {
                { Get-PASLinuxDirectoryGuard @($path) } |
                    Should -Throw '*Unsafe Linux directory guard path*'
            }
        }
        It 'refuses untrusted infrastructure before copying payloads or receiving secrets' {
            Mock Invoke-PASRawSSH { return @{ExitCode = 0; Output = '' } }
            Mock Invoke-PASLinuxControl { throw 'unsafe infrastructure' }
            Mock Copy-PASRawSSH {}
            { Initialize-PASLinuxDetached @{User = 'root' } 'unused.sh' @{Fixture = 'not-secret' } ('a' * 32) 60 Object } |
                Should -Throw '*unsafe infrastructure*'
            Should -Invoke Copy-PASRawSSH -Times 0 -Exactly
        }
        It 'checks existing application path types and immutable attempt absence before chmod or mkdir' {
            $script:AttemptPreparation = ''
            Mock Invoke-PASRawSSH { return @{ExitCode = 0; Output = '' } }
            Mock Invoke-PASLinuxControl {
                param(
                    $Target,
                    $Command
                )
                $script:AttemptPreparation = $Command
                throw 'captured before mutation'
            }
            { Initialize-PASLinuxDetached @{User = 'root' } 'unused.sh' @{} ('b' * 32) 60 Object } | Should -Throw '*captured before mutation*'
            $guard = $script:AttemptPreparation.IndexOf('for p in /opt/paeasyinstall /opt/paeasyinstall/attempts /opt/paeasyinstall/attempts/' + ('b' * 32))
            $guard | Should -BeGreaterThan -1
            $guard | Should -BeLessThan $script:AttemptPreparation.IndexOf('chmod 700')
            $script:AttemptPreparation.IndexOf('test ! -e /opt/paeasyinstall/attempts/' + ('b' * 32)) |
                Should -BeLessThan $script:AttemptPreparation.IndexOf('chmod 700')
        }
        It 'guards secret receipt as well as controller-authored filesystem operations' {
            Mock Invoke-PASLinuxControl { return '' }
            Mock Copy-PASRawSSH {}
            Mock Start-PASLinuxDetached {}
            $script:StreamGuard = ''
            Mock Invoke-PASRawSSH {
                param(
                    $Target,
                    $RemoteCommand,
                    $InputBytes
                )
                if ($RemoteCommand -like '*head -c*inputs.json*') { $script:StreamGuard = $RemoteCommand }
                return @{
                    ExitCode = 0
                    Output = ''
                }
            }
            $task = Join-Path $TestDrive 'fixture.sh'
            [IO.File]::WriteAllText($task, 'echo fixture')
            $null = Initialize-PASLinuxDetached @{User = 'root' } $task @{Fixture = 'not-secret' } ('a' * 32) 60 Object
            $script:StreamGuard | Should -Match '^set -eu; for p in / /opt /run'
            $script:StreamGuard | Should -Match '/run/paeasyinstall/attempts/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
            $script:StreamGuard.IndexOf('stat -c %u') | Should -BeLessThan $script:StreamGuard.IndexOf('head -c')
        }
    }
}
