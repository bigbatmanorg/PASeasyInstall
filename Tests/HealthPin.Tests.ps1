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
