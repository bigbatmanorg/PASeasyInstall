BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1'); Import-PASTestModule
}
Describe 'Linux media transfer destination admission' {
    InModuleScope PASeasyInstall {
        It 'rejects traversal, shell syntax, ambiguous separators and directory destinations' {
            foreach($path in @('/opt/paeasyinstall/../bad','/opt/paeasyinstall/media/./bad','/opt/paeasyinstall/media/','/opt/paeasyinstall//bad','/opt/paeasyinstall/media/a;id','/etc/passwd')){
                {Get-PASLinuxFilePreparation $path}|Should -Throw '*Unsafe Linux transfer*'
            }
        }
        It 'admits the complete ancestor chain before invoking SCP' {
            $script:TransferCalls=New-Object Collections.ArrayList
            Mock Invoke-PASLinuxControl {param($Target,$Command);[void]$script:TransferCalls.Add('PREPARE');$Command|Should -Match 'trusted /';$Command|Should -Match 'stat -c %h'}
            Mock Copy-PASRawSSH {[void]$script:TransferCalls.Add('COPY')}
            Copy-PASAdapterFile @{Protocol='SSH';Runtime='Bash';User='root'} @{} 'fixture.zip' '/opt/paeasyinstall/media/psmp.zip'
            ($script:TransferCalls -join ',')|Should -BeExactly 'PREPARE,COPY'
        }
        It 'never invokes SCP after admission fails or an unqualified identity is selected' {
            Mock Invoke-PASLinuxControl {throw 'unsafe ancestor'}
            Mock Copy-PASRawSSH {throw 'must not copy'}
            {Copy-PASAdapterFile @{Protocol='SSH';Runtime='Bash';User='root'} @{} 'fixture.zip' '/opt/paeasyinstall/media/psmp.zip'}|Should -Throw '*unsafe ancestor*'
            {Copy-PASAdapterFile @{Protocol='SSH';Runtime='Bash';User='operator'} @{} 'fixture.zip' '/opt/paeasyinstall/media/psmp.zip'}|Should -Throw '*root SSH identity*'
            Should -Invoke Copy-PASRawSSH -Times 0 -Exactly
        }
    }
}
