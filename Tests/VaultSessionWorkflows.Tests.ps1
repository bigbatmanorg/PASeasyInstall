BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Vault installation credential admission' {
    InModuleScope PASeasyInstall.Core {
        BeforeEach {
            $config=@{components=@(@{type='Vault'},@{type='DRVault'})}
            $secrets=@{VaultAdmin=(ConvertTo-SecureString 'synthetic-admin' -AsPlainText -Force);DRPassword=(ConvertTo-SecureString 'synthetic-dr' -AsPlainText -Force);VaultMaster=(ConvertTo-SecureString 'synthetic-master' -AsPlainText -Force)}
        }
        It 'accepts qualified native installation text' {
            $secrets.VaultMaster=ConvertTo-SecureString 'Master-ASCII' -AsPlainText -Force
            {Assert-PASVaultInstallationSecrets $config $secrets}|Should -Not -Throw
        }
        It 'refuses unsupported admin or DR text without echoing its value' {
            foreach($name in @('VaultAdmin','DRPassword')){
                $saved=$secrets[$name]
                foreach($bad in @('synthetic-"-marker','synthetic-非ASCII',"synthetic`nmarker")){
                    $secrets[$name]=ConvertTo-SecureString $bad -AsPlainText -Force
                    $errorText='';try{Assert-PASVaultInstallationSecrets $config $secrets}catch{$errorText=$_.Exception.Message}
                    $errorText|Should -Match 'requires printable ASCII'
                    $errorText|Should -Not -Match 'synthetic'
                }
                $secrets[$name]=$saved
            }
        }
        It 'requires typed nonempty SecureStrings' {
            foreach($value in @($null,'synthetic-string',[Security.SecureString]::new())){
                $secrets.VaultAdmin=$value
                {Assert-PASVaultInstallationSecrets $config $secrets}|Should -Throw '*SecureString is required*'
            }
        }
        It 'rejects missing, plaintext, empty or unrepresentable Master before a mixed AD and Vault deployment' {
            $config.components+=@{type='AD'}
            foreach($value in @($null,'synthetic-master',[Security.SecureString]::new(),(ConvertTo-SecureString "synthetic`nmaster" -AsPlainText -Force),(ConvertTo-SecureString 'synthetic-非ASCII' -AsPlainText -Force),(ConvertTo-SecureString 'synthetic-"-master' -AsPlainText -Force))){
                $secrets.VaultMaster=$value
                {Assert-PASVaultInstallationSecrets $config $secrets}|Should -Throw '*VaultMaster*'
            }
        }
        It 'rejects bad Master at the public Start boundary before environment admission or controller dispatch' {
            $config.components+=@{type='AD'};$config.name='synthetic-early-admission'
            $secrets.Remove('VaultMaster')
            Mock Test-PASConfiguration {return @{Valid=$true;Configuration=@{name='synthetic-early-admission';components=@(@{type='AD'},@{type='Vault'})}}}
            Mock Get-PASDeploymentPlan {return @{Items=@()}}
            Mock Assert-PASWindowsController {}
            Mock Test-PASActiveEnvironment {throw 'Unexpected environment admission'}
            Mock Invoke-PASRunController {throw 'Unexpected target dispatch'}
            {Start-PASDeployment -Configuration $config -SecretMap $secrets -Foreground}|Should -Throw '*VaultMaster*'
            Should -Invoke Test-PASActiveEnvironment -Times 0 -Exactly
            Should -Invoke Invoke-PASRunController -Times 0 -Exactly
        }
        It 'returns the WhatIf plan without credentials or environment/controller dispatch' {
            Mock Test-PASConfiguration {return @{Valid=$true;Configuration=@{name='synthetic-whatif';components=@(@{type='Vault'})}}}
            Mock Get-PASDeploymentPlan {return @{Items=@(@{Type='Vault'})}}
            Mock Assert-PASWindowsController {}
            Mock Assert-PASVaultInstallationSecrets {throw 'Unexpected credential admission'}
            Mock Test-PASActiveEnvironment {throw 'Unexpected environment admission'}
            Mock Invoke-PASRunController {throw 'Unexpected target dispatch'}
            $plan=Start-PASDeployment -Configuration $config -WhatIf
            $plan.Items.Count|Should -Be 1
            Should -Invoke Assert-PASVaultInstallationSecrets -Times 0 -Exactly
            Should -Invoke Test-PASActiveEnvironment -Times 0 -Exactly
            Should -Invoke Invoke-PASRunController -Times 0 -Exactly
        }
        It 'leaves existing-Vault component credentials to their own REST contract' {
            {Assert-PASVaultInstallationSecrets @{components=@(@{type='PVWA'})} @{}}|Should -Not -Throw
        }
        It 'does not require DR credentials for a standalone Primary' {
            $secrets.Remove('DRPassword')
            {Assert-PASVaultInstallationSecrets @{components=@(@{type='Vault'})} $secrets}|Should -Not -Throw
        }
    }
}
Describe 'All authenticated Vault recipe paths use durable session coordination' {
    BeforeAll {$workflowRoot=Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Vault/Recipes/Vault/Workflows'}
    It 'declares detached authenticated actions and independent check sessions in every workflow' {
        $actions=0;$checks=0
        foreach($file in Get-ChildItem $workflowRoot -Recurse -Filter *.psd1){
            $workflow=Import-PowerShellDataFile $file.FullName
            foreach($step in $workflow.Steps){
                if($step.Script -in @('Tasks/Vault/Configure-Primary.ps1','Tasks/Vault/New-TestSafe.ps1')){
                    $actions++;$step.Mode|Should -BeExactly Detached;$step.RequiresVaultSession|Should -BeTrue
                }
                if($step.Verify -in @('Tasks/Verify/Verify-Primary.ps1','Tasks/Verify/Verify-TestSafe.ps1')){
                    $checks++;$step.VerifyMode|Should -BeExactly Detached;$step.VerifyRequiresVaultSession|Should -BeTrue
                    $step.Script|Should -Not -Be 'Tasks/Verify/Verify-Primary.ps1'
                }
            }
        }
        $actions|Should -Be 5
        $checks|Should -Be 10
    }
}
