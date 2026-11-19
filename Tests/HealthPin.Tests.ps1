# Test-PASEnvironmentHealth must reuse the PVWA certificate that the composed deployment captured for CPM
# (pvwaTrustFrom); otherwise a lab PVWA's self-signed certificate fails system trust.
BeforeAll {
    $env:PAS_EASY_DATA_ROOT = Join-Path $TestDrive 'data'
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Orchestrator/PASeasyInstall.Orchestrator.psd1') -Force
}
Describe 'Health check PVWA certificate pin' {
    It 'uses the certificate captured by this environment''s composed deployment' {
        InModuleScope PASeasyInstall.Orchestrator {
            $root = Get-PASFleetRoot
            foreach ($n in @(@{ id = 'a' * 32; name = 'OtherLab' }, @{ id = 'b' * 32; name = 'LabB' })) {
                $d = Join-Path $root $n.id; New-Item -ItemType Directory -Force $d | Out-Null
                Write-PASFleetJson (Join-Path $d 'fleet.json') ([ordered]@{ schemaVersion = 1; id = $n.id; name = $n.name; status = 'Succeeded'; units = @() })
                Set-Content (Join-Path $d 'pvwa-trust-lb-pvwacpm.cer') $n.name
            }
            $cfg = @{ name = 'LabB'; components = @(@{ id = 'lb-cpm'; type = 'CPM'; options = @{ pvwaTrustFrom = 'lb-pvwacpm' } }) }
            $pin = Get-PASHealthPinnedCertificate $cfg ''
            $pin | Should -BeLike ('*' + ('b' * 32) + '*pvwa-trust-lb-pvwacpm.cer')
        }
    }
    It 'prefers an explicit certificate file and returns nothing without a pin' {
        InModuleScope PASeasyInstall.Orchestrator {
            Get-PASHealthPinnedCertificate @{ name = 'X'; components = @() } 'C:\given.cer' | Should -Be 'C:\given.cer'
            Get-PASHealthPinnedCertificate @{ name = 'NoSuchLab'; components = @(@{ id = 'c'; type = 'CPM'; options = @{ pvwaTrustFrom = 'p' } }) } '' | Should -Be ''
        }
    }
}
