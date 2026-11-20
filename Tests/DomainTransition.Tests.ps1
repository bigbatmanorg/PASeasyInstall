BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1'); Import-PASTestModule
}
InModuleScope PASeasyInstall {
    Describe 'Explicit AD credential transition' {
        BeforeEach {$script:PSConnections=@{}}
        It 'uses the provided post-promotion identity after the local identity is rejected' {
            $secret=ConvertTo-SecureString 'synthetic-value' -AsPlainText -Force
            $creds=@{before=[pscredential]::new('BEFORE\Administrator',$secret);after=[pscredential]::new('PAM\Administrator',$secret)}
            Mock New-PSSession {
                param($Credential)
                if($Credential.UserName -eq 'BEFORE\Administrator'){throw 'Access is denied'}
                [pscustomobject]@{State='Opened';Availability='Available'}
            }
            $target=@{Protocol='WinRM';ComputerName='fixture.invalid';CredentialRef='before';TransitionCredentialRef='after';ConfigurationName='Microsoft.PowerShell';UseSSL=$true;ConnectRetrySeconds=0}
            (Get-PASConnection $target $creds).State | Should -Be 'Opened'
            Should -Invoke New-PSSession -Times 2 -Exactly
        }
        It 'does not invent or guess a post-promotion credential' {
            $secret=ConvertTo-SecureString 'synthetic-value' -AsPlainText -Force
            Mock New-PSSession {throw 'should never connect'}
            $target=@{Protocol='WinRM';ComputerName='fixture.invalid';CredentialRef='before';TransitionCredentialRef='absent'}
            {Get-PASConnection $target @{before=[pscredential]::new('BEFORE\Administrator',$secret)}} | Should -Throw '*transition credential*'
            Should -Invoke New-PSSession -Times 0 -Exactly
        }
    }
}
