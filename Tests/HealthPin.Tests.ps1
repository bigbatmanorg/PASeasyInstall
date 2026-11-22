# Test-PASHealth must reuse the PVWA certificate that a run of this environment captured for CPM
# (pvwaTrustFrom); otherwise a lab PVWA's self-signed certificate fails system trust.
BeforeAll {
    $script:SavedDataRoot = $env:PAS_EASY_DATA_ROOT
    $env:PAS_EASY_DATA_ROOT = Join-Path $TestDrive 'data'
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
}
AfterAll { $env:PAS_EASY_DATA_ROOT = $script:SavedDataRoot }
Describe 'Health check PVWA certificate pin' {
    It 'uses the certificate captured by a run of this environment' {
        InModuleScope PASeasyInstall {
            foreach ($n in @(@{ id = 'a' * 32; name = 'OtherLab' }, @{ id = 'b' * 32; name = 'LabB' })) {
                $d = Get-PASRunDirectory $n.id
                New-Item -ItemType Directory -Force $d | Out-Null
                Write-PASJsonAtomic (Join-Path $d 'run.json') ([ordered]@{
                        schemaVersion = 2
                        id = $n.id
                        name = $n.name
                        status = 'Succeeded'
                        startedUtc = [DateTime]::UtcNow.ToString('o')
                    })
                Set-Content (Join-Path $d 'pvwa-trust-lb-pvwacpm.cer') $n.name
            }
            $cfg = @{
                name = 'LabB'
                components = @(@{
                        id = 'lb-cpm'
                        type = 'CPM'
                        options = @{ pvwaTrustFrom = 'lb-pvwacpm' }
                    })
            }
            $pin = Get-PASHealthPinnedCertificate $cfg ''
            $pin | Should -BeLike ('*' + ('b' * 32) + '*pvwa-trust-lb-pvwacpm.cer')
        }
    }
    It 'prefers an explicit certificate file and returns nothing without a pin' {
        InModuleScope PASeasyInstall {
            Get-PASHealthPinnedCertificate @{ name = 'X'; components = @() } 'C:\given.cer' | Should -Be 'C:\given.cer'
            Get-PASHealthPinnedCertificate @{
                name = 'NoSuchLab'
                components = @(@{
                        id = 'c'
                        type = 'CPM'
                        options = @{ pvwaTrustFrom = 'p' }
                    })
            } '' |
                Should -Be ''
        }
    }
}

Describe 'Health check when the PVWA name does not resolve' {
    BeforeAll {
        $script:healthCfg = @{
            hosts = @{ web1 = @{ address = '192.0.2.21' }; web2 = @{ address = '192.0.2.22' } }
            components = @(
                @{ id = 'pvwa1'; type = 'PVWA'; host = 'web1'; options = @{ pvwaUrl = 'https://pasweb1/PasswordVault' } },
                @{ id = 'pvwa2'; type = 'PVWA'; host = 'web2'; options = @{ pvwaUrl = 'https://pasweb2:8443/PasswordVault' } })
        }
    }
    It 'connects to the address of the configuration and sends the name' {
        InModuleScope PASeasyInstall -Parameters @{ cfg = $script:healthCfg } {
            param($cfg)
            Mock Test-PASNameResolves { $false }
            $one = Get-PASHealthPvwaConnection $cfg ([uri]'https://pasweb1/PasswordVault/API')
            $one.Api | Should -Be 'https://192.0.2.21/PasswordVault/API'
            $one.Headers.Host | Should -Be 'pasweb1'
            $one.Problem | Should -BeNullOrEmpty
            $two = Get-PASHealthPvwaConnection $cfg ([uri]'https://pasweb2:8443/PasswordVault/API')
            $two.Api | Should -Be 'https://192.0.2.22:8443/PasswordVault/API'
            $two.Headers.Host | Should -Be 'pasweb2:8443'
        }
    }
    It 'uses the URL as it is when the name resolves' {
        InModuleScope PASeasyInstall -Parameters @{ cfg = $script:healthCfg } {
            param($cfg)
            Mock Test-PASNameResolves { $true }
            $one = Get-PASHealthPvwaConnection $cfg ([uri]'https://pasweb1/PasswordVault/API')
            $one.Api | Should -Be 'https://pasweb1/PasswordVault/API'
            $one.Headers.Count | Should -Be 0
        }
    }
    It 'names the problem when the configuration has no IP address for the PVWA' {
        InModuleScope PASeasyInstall {
            Mock Test-PASNameResolves { $false }
            $cfg = @{ hosts = @{ web1 = @{ address = 'pasweb1' } }; components = @(@{ id = 'pvwa1'; type = 'PVWA'; host = 'web1'; options = @{} }) }
            (Get-PASHealthPvwaConnection $cfg ([uri]'https://pasweb1/PasswordVault/API')).Problem | Should -Match "does not resolve.*hosts"
        }
    }
}
