BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Linux terminal evidence reconstruction' {
    InModuleScope PASeasyInstall.Core {
        BeforeEach {
            $script:ObserverFixtureContract='Object'
            $script:ObserverFixtureTail='PAEASY_RESULT:{"Changed":false,"Message":"fixture","Data":{"Hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","TrustBundleSHA256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}'
            Mock Invoke-PSLinuxControl {
                param($Target,$Command)
                if($Command -like 'cat -- */contract.txt'){return $script:ObserverFixtureContract}
                if($Command -like 'tail -c *stdout.log.tail'){return $script:ObserverFixtureTail}
                return '{"schemaVersion":2,"state":"Succeeded","workerActive":false,"attemptId":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","pid":123,"bootId":"11111111-1111-1111-1111-111111111111","exitCode":0}'
            }
        }
        It 'recovers approved Data and Changed from the durable Object marker' {
            $r=Get-PSLinuxDetachedStatus @{} ('a'*32)
            $r.data.Hash | Should -Be ('a'*64)
            $r.data.TrustBundleSHA256 | Should -Be ('b'*64)
            $r.changed | Should -BeFalse
        }
        It 'refuses successful Object status with an empty or missing marker' {
            $script:ObserverFixtureTail='ordinary output only'
            {Get-PSLinuxDetachedStatus @{} ('a'*32)} | Should -Throw '*PAExecUnknown*no terminal result marker*'
        }
        It 'refuses malformed Object marker JSON' {
            $script:ObserverFixtureTail='PAEASY_RESULT:{bad'
            {Get-PSLinuxDetachedStatus @{} ('a'*32)} | Should -Throw '*malformed*'
        }
        It 'refuses unknown durable contract instead of assuming ExitCode' {
            $script:ObserverFixtureContract=''
            {Get-PSLinuxDetachedStatus @{} ('a'*32)} | Should -Throw '*terminal contract*'
        }
        It 'allows a real ExitCode contract to omit a result object' {
            $script:ObserverFixtureContract='ExitCode'
            $script:ObserverFixtureTail='ordinary output only'
            (Get-PSLinuxDetachedStatus @{} ('a'*32)).state | Should -Be Succeeded
        }
    }
}
