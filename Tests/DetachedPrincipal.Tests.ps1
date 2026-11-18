BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force -Scope Global
}
Describe 'Detached task identity credential boundary' {
    InModuleScope PASeasyInstall.Core {
        It 'uses SYSTEM when no alternate principal was explicitly requested' {
            Resolve-PSDetachedPrincipalCredential -Credentials @{} | Should -BeNullOrEmpty
        }
        It 'fails an absent principal reference before remote staging' {
            {Resolve-PSDetachedPrincipalCredential -Credentials @{} -Reference 'PsmDomain'} | Should -Throw '*PSCredential*'
        }
        It 'rejects plaintext or arbitrary principal map values' {
            {Resolve-PSDetachedPrincipalCredential -Credentials @{PsmDomain='synthetic-secret'} -Reference 'PsmDomain'} | Should -Throw '*PSCredential*'
        }
        It 'rejects local or ambiguous usernames for a domain task' {
            foreach($user in @('Administrator','.\Administrator','localhost\Administrator','NT AUTHORITY\SYSTEM')){
                $credential=[pscredential]::new($user,(ConvertTo-SecureString 'synthetic-marker' -AsPlainText -Force))
                {Resolve-PSDetachedPrincipalCredential -Credentials @{PsmDomain=$credential} -Reference 'PsmDomain'} | Should -Throw '*Domain task identity*'
            }
        }
        It 'preserves domain credentials as PSCredential without exposing their password in results' {
            foreach($user in @('PAM\installer','installer@pam.test')){
                $credential=[pscredential]::new($user,(ConvertTo-SecureString 'synthetic-marker' -AsPlainText -Force))
                $resolved=Resolve-PSDetachedPrincipalCredential -Credentials @{PsmDomain=$credential} -Reference 'PsmDomain'
                $resolved | Should -BeOfType ([pscredential])
                $resolved.UserName | Should -Be $user
                ($resolved | ConvertTo-Json -Compress) | Should -Not -Match 'synthetic-marker'
            }
        }
        It 'rejects unsafe credential reference syntax before looking up a map' {
            {Resolve-PSDetachedPrincipalCredential -Credentials @{} -Reference '../PsmDomain'} | Should -Throw '*Invalid detached task principal*'
        }
    }
}
