BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Linux media transfer destination admission' {
    InModuleScope PASeasyInstall.Core {
        It 'rejects traversal, shell syntax, ambiguous separators and directory destinations' {
            foreach($path in @('/opt/paeasyinstall/../bad','/opt/paeasyinstall/media/./bad','/opt/paeasyinstall/media/','/opt/paeasyinstall//bad','/opt/paeasyinstall/media/a;id','/etc/passwd')){
                {Get-PSLinuxFilePreparation $path}|Should -Throw '*Unsafe Linux transfer*'
            }
        }
        It 'admits the complete ancestor chain before invoking SCP' {
            $script:TransferCalls=New-Object Collections.ArrayList
            Mock Invoke-PSLinuxControl {param($Target,$Command);[void]$script:TransferCalls.Add('PREPARE');$Command|Should -Match 'trusted /';$Command|Should -Match 'stat -c %h'}
            Mock Copy-PSRawSSH {[void]$script:TransferCalls.Add('COPY')}
            Copy-PSAdapterFile @{Protocol='SSH';Runtime='Bash';User='root'} @{} 'fixture.zip' '/opt/paeasyinstall/media/pta.zip'
            ($script:TransferCalls -join ',')|Should -BeExactly 'PREPARE,COPY'
        }
        It 'never invokes SCP after admission fails or an unqualified identity is selected' {
            Mock Invoke-PSLinuxControl {throw 'unsafe ancestor'}
            Mock Copy-PSRawSSH {throw 'must not copy'}
            {Copy-PSAdapterFile @{Protocol='SSH';Runtime='Bash';User='root'} @{} 'fixture.zip' '/opt/paeasyinstall/media/pta.zip'}|Should -Throw '*unsafe ancestor*'
            {Copy-PSAdapterFile @{Protocol='SSH';Runtime='Bash';User='operator'} @{} 'fixture.zip' '/opt/paeasyinstall/media/pta.zip'}|Should -Throw '*root SSH identity*'
            Should -Invoke Copy-PSRawSSH -Times 0 -Exactly
        }
    }
}
