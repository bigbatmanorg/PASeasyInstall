BeforeAll {
    # Isolate the actual pure predicate from a target-side verifier without running
    # its OS inspection body in the Pester process.
    $path=Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Vault/Recipes/Vault/Tasks/Verify/Verify-Hardening.ps1'
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if($errors){throw 'Target verifier does not parse'}
    $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-PASeasyVaultNativeInboundPort'},$true)
    if(-not $definition){throw 'Native inbound port policy missing'}
    . ([scriptblock]::Create($definition.Extent.Text))
}
Describe 'Vault firewall exception admission' {
    It 'accepts only the single native TCP1858 listener' {
        foreach($protocol in @('TCP','6')){Test-PASeasyVaultNativeInboundPort @{Protocol=$protocol;LocalPort='1858'}|Should -BeTrue}
    }
    It 'does not trust a vendor label to admit RDP WinRM or other services' {
        foreach($port in @('3389','5986','445','Any','1-65535')){
            Test-PASeasyVaultNativeInboundPort @{Protocol='TCP';LocalPort=$port;Group='CYBERARK_RULE_INSTALLATION';DisplayName='CyberArk Vault'}|Should -BeFalse
        }
    }
    It 'rejects mixed listeners and non-TCP traffic' {
        Test-PASeasyVaultNativeInboundPort @{Protocol='TCP';LocalPort=@('1858','3389')}|Should -BeFalse
        Test-PASeasyVaultNativeInboundPort @{Protocol='UDP';LocalPort='1858'}|Should -BeFalse
        Test-PASeasyVaultNativeInboundPort @{Protocol='Any';LocalPort='1858'}|Should -BeFalse
    }
}
