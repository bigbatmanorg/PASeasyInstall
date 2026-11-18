BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Linux same-boot durable publication' {
    InModuleScope PASeasyInstall.Core {
        It 'publishes staged boot and flushes filesystems before first start' {
            $script:PublicationCalls=New-Object Collections.ArrayList
            Mock Invoke-PSRawSSH {return @{ExitCode=0;Output=''}}
            Mock Invoke-PSLinuxControl {param($Target,$Command);[void]$script:PublicationCalls.Add($Command);return ''}
            Mock Copy-PSRawSSH {}
            Mock Start-PSLinuxDetached {[void]$script:PublicationCalls.Add('START')}
            $task=[IO.Path]::GetTempFileName()
            try {
                [IO.File]::WriteAllText($task,'echo fixture')
                $null=Initialize-PSLinuxDetached @{User='root'} $task @{Fixture='nonsecret'} ('a'*32) 60 Object
                $publish=@($script:PublicationCalls|Where-Object {$_ -like '*stagedBootId*'})
                $publish.Count | Should -Be 1
                $publish[0] | Should -Match 'attemptId:\$id,stagedBootId:\$boot'
                $publish[0] | Should -Match 'sync -f /opt/paeasyinstall/attempts/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; sync -f /etc/systemd/system'
                $script:PublicationCalls.IndexOf($publish[0]) | Should -BeLessThan $script:PublicationCalls.IndexOf('START')
                @($script:PublicationCalls|Where-Object {$_ -like '*command -v sync*sync -f /opt*'}).Count | Should -Be 1
            } finally {Remove-Item $task -Force -ErrorAction SilentlyContinue}
        }
        It 'repeats required filesystem barriers before a resumed same-attempt start' {
            $script:ResumeStartCommand=''
            Mock Invoke-PSLinuxControl {param($Target,$Command);$script:ResumeStartCommand=$Command;return ''}
            Start-PSLinuxDetached @{} ('b'*32)
            $script:ResumeStartCommand | Should -Match 'sync -f /opt/paeasyinstall/attempts/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; sync -f /etc/systemd/system; systemctl daemon-reload; systemctl start'
        }
    }
}
