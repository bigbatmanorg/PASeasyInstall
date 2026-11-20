BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'PTA public Vault syslog continuation admission' {
    InModuleScope PASeasyInstall.Core {
        BeforeEach {
            $config=New-PASConfigurationTemplate -Template FullLab -Path (Join-Path $TestDrive 'sample.json') -WhatIf
            $config.components=@($config.components|Where-Object type -eq PTA);$config.vault.existing=$true
        }
        It 'selects the exact existing primary host and refuses an absent or non-Windows management host' {
            Get-PASPTASyslogHost $config|Should -BeExactly vault01
            ((Get-PASDeploymentHostIds $config) -join ',')|Should -BeExactly 'pta01,vault01'
            $config.vault.managementHost='pta01'
            (Test-PASConfiguration -Configuration $config).Valid|Should -BeFalse
            $config.vault.managementHost='absent'
            (Test-PASConfiguration -Configuration $config).Valid|Should -BeFalse
            $config.vault.Remove('managementHost');$config.hosts.Remove('vault01')
            (Test-PASConfiguration -Configuration $config).Valid|Should -BeFalse
        }
        It 'allows omission only with an explicitly audited Lab deviation' {
            $config.security.overrides=@{'PTA.SkipVaultSyslog'=$true}
            (Test-PASConfiguration -Configuration $config).Valid|Should -BeFalse
            $config.security.profile='Lab'
            $assessment=Test-PASConfiguration -Configuration $config
            $assessment.Valid|Should -BeTrue
            ($assessment.Warnings -join ';')|Should -Match 'SECURITY DEVIATION: PTA.SkipVaultSyslog = True'
            Get-PASPTASyslogHost $config|Should -BeNullOrEmpty
        }
        It 'refuses a component id that would overwrite the continuation journal or payload' {
            $config.components+=@{id='pta-vault-syslog';type='PVWA';host='pam01';options=@{}}
            $assessment=Test-PASConfiguration -Configuration $config
            $assessment.Valid|Should -BeFalse
            ($assessment.Issues -join ';')|Should -Match 'reserved PTA Vault syslog continuation'
        }
        It 'refuses a management address alias to another machine before contacting Linux or Windows' {
            $config.vault.managementHost='pam01'
            $cred=[pscredential]::new('fixture',(ConvertTo-SecureString 'synthetic' -AsPlainText -Force))
            Mock Get-PASeasyPTATrustBundle {throw 'must not read'}
            {Invoke-PASeasyPTAVaultSyslog $config $config.components[0] @{} 'fixture' $TestDrive @{pam01=$cred} @{}}|Should -Throw '*uniquely resolve*'
            Should -Invoke Get-PASeasyPTATrustBundle -Times 0 -Exactly
        }
        It 'refuses absent primary OS credentials before dispatch' {
            {Invoke-PASeasyPTAVaultSyslog $config $config.components[0] @{} 'fixture' $TestDrive @{} @{}}|Should -Throw '*primary Windows credentials*'
        }
        It 'generates a valid detached session-gated workflow and preserves outer host claim ownership' {
            $script:CompletedSyslogGate=$false;$script:DisposedSyslogGate=$false
            Mock Read-PASJson {return [pscustomobject]@{steps=[pscustomobject]@{configuretls=[pscustomobject]@{status='Succeeded';data=[pscustomobject]@{TrustBundleSHA256=('A'*64)}}}}}
            Mock Get-PASeasyPTATrustBundle {return [pscustomobject]@{Base64='public-fixture';SHA256=('A'*64)}}
            Mock Enter-PASGate {
                $gate=[pscustomobject]@{PreexistingClaim=$true}
                $gate|Add-Member ScriptMethod Complete {$script:CompletedSyslogGate=$true}
                $gate|Add-Member ScriptMethod Dispose {$script:DisposedSyslogGate=$true}
                return $gate
            }
            Mock Write-PASRunEvent {}
            Mock Invoke-PASWorkflow {
                param($WorkflowPath,$InventoryPath,$VaultSessionAddress)
                $plan=Get-PASWorkflowPlan $WorkflowPath $InventoryPath
                $plan.Target.Protocol|Should -BeExactly WinRM
                $plan.Target.CredentialRef|Should -BeExactly vault01
                $plan.Target.ConfigurationName|Should -BeExactly PAExec.Management
                $plan.Target.UseSSL|Should -BeTrue
                $plan.Steps[0].Mode|Should -BeExactly Detached
                $plan.Steps[0].RequiresVaultSession|Should -BeTrue
                $plan.Steps[0].Verify|Should -BeExactly Verify.ps1
                $VaultSessionAddress|Should -BeExactly '192.0.2.11'
            }
            $cred=[pscredential]::new('fixture',(ConvertTo-SecureString 'synthetic' -AsPlainText -Force))
            $inventory=@{Targets=@{pta=@{Protocol='SSH';Runtime='Bash';User='root'}};Values=@{Components=@{pta=@{StageRoot='/opt/paeasyinstall/components/pta'}}}}
            Invoke-PASeasyPTAVaultSyslog $config $config.components[0] $inventory ('a'*32) $TestDrive @{vault01=$cred} @{}
            Should -Invoke Invoke-PASWorkflow -Times 1 -Exactly
            $script:CompletedSyslogGate|Should -BeFalse
            $script:DisposedSyslogGate|Should -BeTrue
        }
    }
}
Describe 'PTA public certificate checkpoint transfer' {
    InModuleScope PASeasyInstall.Core {
        BeforeEach {
            $script:BundleBytes=[Text.Encoding]::ASCII.GetBytes(('-----BEGIN CERTIFICATE-----' + ('A'*120) + '-----END CERTIFICATE-----'))
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$script:BundleHash=([BitConverter]::ToString($sha.ComputeHash($script:BundleBytes))).Replace('-','')}finally{$sha.Dispose()}
            Mock Invoke-PASLinuxControl {return (@{Hash=$script:BundleHash;Base64=[Convert]::ToBase64String($script:BundleBytes);Bytes=$script:BundleBytes.Length}|ConvertTo-Json -Compress)}
        }
        It 'accepts only bytes matching both the remote hash and the approved TLS checkpoint' {
            $result=Get-PASeasyPTATrustBundle @{ComponentStageRoot='/opt/paeasyinstall/components/pta'} $script:BundleHash
            $result.SHA256|Should -BeExactly $script:BundleHash
            {Get-PASeasyPTATrustBundle @{ComponentStageRoot='/opt/paeasyinstall/components/pta'} ('B'*64)}|Should -Throw '*changed after its TLS checkpoint*'
        }
        It 'refuses private-key content and unqualified certificate paths' {
            $script:BundleBytes=[Text.Encoding]::ASCII.GetBytes(('PRIVATE KEY'+('A'*120)))
            $sha=[Security.Cryptography.SHA256]::Create()
            try{$script:BundleHash=([BitConverter]::ToString($sha.ComputeHash($script:BundleBytes))).Replace('-','')}finally{$sha.Dispose()}
            {Get-PASeasyPTATrustBundle @{ComponentStageRoot='/opt/paeasyinstall/components/pta'} $script:BundleHash}|Should -Throw '*only public certificates*'
            {Get-PASeasyPTATrustBundle @{ComponentStageRoot='/tmp/attacker'} $script:BundleHash}|Should -Throw '*Unqualified PTA certificate workspace*'
        }
    }
}
