BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Static Vault task helper dispatch' {
    InModuleScope PASeasyInstall.Core {
        BeforeEach {
            $script:OriginalPayloadRoot=$script:PASRoot
            $script:PASRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $script:PayloadFixtureRoot=$script:PASRoot
            foreach($dir in @('Recipes/Vault/Tasks/Common','Recipes/Vault/Tasks/Verify','Recipes/WindowsComponent')){
                New-Item -ItemType Directory -Path (Join-Path $script:PASRoot $dir) -Force|Out-Null
            }
            $script:PayloadTask=Join-Path $script:PASRoot 'Recipes/Vault/Tasks/Common/Prepare-Paths.ps1'
            $script:PayloadHelper=Join-Path $script:PASRoot 'Recipes/Vault/Tasks/Common/VaultWorkspace.ps1'
            [IO.File]::WriteAllText((Join-Path $script:PASRoot 'Recipes/WindowsComponent/Ownership.ps1'),'function OwnershipFixture { return 7 }')
            [IO.File]::WriteAllText($script:PayloadHelper,'function WorkspaceFixture { return ''literal$1\path'' }')
            [IO.File]::WriteAllText($script:PayloadTask,"param()`n# PAEASY_INCLUDE_VAULT_WORKSPACE`nWorkspaceFixture")
        }
        AfterEach {$script:PASRoot=$script:OriginalPayloadRoot}
        It 'expands only the exact shipped marker with literal code and dependency inventory' {
            $payload=Get-PASRecipePayload $script:PayloadTask
            $payload.Text|Should -Not -Match 'PAEASY_INCLUDE_'
            $payload.Files.Count|Should -Be 3
            $payload.Text.IndexOf('function OwnershipFixture')|Should -BeLessThan $payload.Text.IndexOf('function WorkspaceFixture')
            (& ([scriptblock]::Create($payload.Text)))|Should -BeExactly 'literal$1\path'
            $tokens=$null;$errors=$null
            [void][Management.Automation.Language.Parser]::ParseInput($payload.Text,[ref]$tokens,[ref]$errors)
            $errors.Count|Should -Be 0
        }
        It 'changes the executable digest when only an included helper changes' {
            $before=Get-PASFileSetDigest (Get-PASRecipePayload $script:PayloadTask).Files
            [IO.File]::AppendAllText($script:PayloadHelper,"`n# changed helper")
            (Get-PASFileSetDigest (Get-PASRecipePayload $script:PayloadTask).Files)|Should -Not -Be $before
        }
        It 'pins included helpers through actual workflow Script and Verify references' {
            $vault=Join-Path $script:PASRoot 'Recipes/Vault'
            $workflows=Join-Path $vault 'Workflows'
            New-Item -ItemType Directory $workflows|Out-Null
            $workflow=Join-Path $workflows 'fixture.psd1'
            $inventory=Join-Path $TestDrive 'payload-inventory.psd1'
            [IO.File]::WriteAllText($inventory,"@{SchemaVersion=1;Targets=@{fixture=@{Protocol='Local'}}}")
            [IO.File]::WriteAllText((Join-Path $vault 'Tasks/Common/Plain.ps1'),'param(); [pscustomobject]@{Changed=$false}')
            foreach($references in @("Script='Tasks/Common/Prepare-Paths.ps1'","Script='Tasks/Common/Plain.ps1';Verify='Tasks/Common/Prepare-Paths.ps1'")){
                [IO.File]::WriteAllText($workflow,("@{SchemaVersion=1;Name='fixture';Target='fixture';Root='..';Steps=@(@{Id='fixture';"+$references+'})}'))
                $before=(Get-PASWorkflowPlan $workflow $inventory).Digest
                [IO.File]::AppendAllText($script:PayloadHelper,"`n# additional helper change")
                (Get-PASWorkflowPlan $workflow $inventory).Digest|Should -Not -Be $before
            }
        }
        It 'refuses unknown, duplicate, nested and misplaced includes' {
            foreach($body in @('# PAEASY_INCLUDE_UNKNOWN',"# PAEASY_INCLUDE_VAULT_WORKSPACE`n# PAEASY_INCLUDE_VAULT_WORKSPACE")){
                [IO.File]::WriteAllText($script:PayloadTask,$body)
                {Get-PASRecipePayload $script:PayloadTask}|Should -Throw '*static Vault helper marker*'
            }
            [IO.File]::WriteAllText($script:PayloadTask,'# PAEASY_INCLUDE_VAULT_WORKSPACE')
            [IO.File]::WriteAllText($script:PayloadHelper,'# PAEASY_INCLUDE_VAULT_PACLI')
            {Get-PASRecipePayload $script:PayloadTask}|Should -Throw '*Nested*'
            $wrong=Join-Path $script:PASRoot 'Recipes/Vault/Tasks/Verify/Other.ps1'
            [IO.File]::WriteAllText($wrong,'# PAEASY_INCLUDE_VAULT_WORKSPACE')
            {Get-PASRecipePayload $wrong}|Should -Throw '*misplaced*'
            $external=Join-Path $TestDrive 'outside.ps1'
            [IO.File]::WriteAllText($external,'# PAEASY_INCLUDE_VAULT_WORKSPACE')
            {Get-PASRecipePayload $external}|Should -Throw '*outside*'
        }
        It 'does not expand arbitrary dot sourcing or marker text inside a string' {
            $raw='param(); $marker="# PAEASY_INCLUDE_VAULT_WORKSPACE"; . ./arbitrary.ps1'
            [IO.File]::WriteAllText($script:PayloadTask,$raw)
            $payload=Get-PASRecipePayload $script:PayloadTask
            $payload.Text|Should -BeExactly $raw
            $payload.Files.Count|Should -Be 1
        }
        It 'uses the same expanded payload in direct dispatch' {
            Mock Invoke-PASLocalTask {
                param($ScriptText,$Parameters)
                return @{Ok=$true;Terminal=(& ([scriptblock]::Create($ScriptText)) @Parameters)}
            }
            $result=Invoke-PASAdapterScript -Target @{Protocol='Local'} -Credentials @{} -ScriptPath $script:PayloadTask -Parameters @{}
            $result.Ok|Should -BeTrue
            $result.Terminal|Should -BeExactly 'literal$1\path'
        }
        It 'pins and parses the exact two RDP policy recipe closures and rejects other callers' {
            $script:PASRoot=$script:OriginalPayloadRoot
            foreach($relative in @('Tasks/Vault/Harden-Vault.ps1','Tasks/Verify/Verify-Hardening.ps1')){
                $payload=Get-PASRecipePayload (Join-Path $script:PASRoot ('Recipes/Vault/'+$relative))
                $payload.Files.Count|Should -Be 2
                $payload.Files|Should -Contain (Join-Path $script:PASRoot 'Recipes/Vault/Tasks/Common/VaultRdp.ps1')
                $payload.Text|Should -Not -Match 'PAEASY_INCLUDE_'
                $tokens=$null;$errors=$null
                [void][Management.Automation.Language.Parser]::ParseInput($payload.Text,[ref]$tokens,[ref]$errors)
                $errors.Count|Should -Be 0
            }
            $script:PASRoot=$script:PayloadFixtureRoot
            [IO.File]::WriteAllText($script:PayloadTask,'# PAEASY_INCLUDE_VAULT_RDP')
            {Get-PASRecipePayload $script:PayloadTask}|Should -Throw '*misplaced*'
        }
        It 'expands the real key closure and keeps generation under SYSTEM with receipt-aware DR relay' {
            $script:PASRoot=$script:OriginalPayloadRoot
            foreach($relative in @('Tasks/Vault/Generate-Keys.ps1','Tasks/Verify/Verify-Keys.ps1')){
                $payload=Get-PASRecipePayload (Join-Path $script:PASRoot ('Recipes/Vault/'+$relative))
                $payload.Files.Count|Should -Be 4
                $payload.Text|Should -Not -Match 'PAEASY_INCLUDE_'
                $tokens=$null;$errors=$null
                [void][Management.Automation.Language.Parser]::ParseInput($payload.Text,[ref]$tokens,[ref]$errors)
                $errors.Count|Should -Be 0
            }
            foreach($name in @('VaultPrimary.psd1','VaultPrimary-Phase1.psd1','VaultPrimaryOnly.psd1')){
                $workflow=Import-PowerShellDataFile (Join-Path $script:PASRoot ('Recipes/Vault/Workflows/'+$name))
                $keygen=@($workflow.Steps|Where-Object {$_.Id -eq 'keygen'})
                $keygen.Count|Should -Be 1
                $keygen[0].Mode|Should -BeExactly Detached
                $keygen[0].ContainsKey('TaskPrincipalCredentialRef')|Should -BeFalse
            }
            foreach($name in @('VaultDR.psd1','VaultDR-Phase1.psd1')){
                $workflow=Import-PowerShellDataFile (Join-Path $script:PASRoot ('Recipes/Vault/Workflows/'+$name))
                $relay=@($workflow.Steps|Where-Object {$_.Id -eq 'relay-shared-keys'})[0]
                $relay.Files|Should -Contain '.paeasy-key-generation.claim.json'
                $relay.Files|Should -Contain '.paeasy-key-generation.json'
            }
        }
    }
}
