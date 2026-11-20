BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
    function New-ReferenceConfig {
        $c=New-PASConfigurationTemplate -Template ExistingVault -Path (Join-Path $TestDrive 'not-written.json') -WhatIf
        $c.hosts.pam01.credentialRef='CustomHostAdministrator'
        return $c
    }
    function New-ReferenceCredential([string]$User) {
        return [pscredential]::new($User,(ConvertTo-SecureString 'SyntheticFixtureOnly' -AsPlainText -Force))
    }
}
Describe 'Windows host credential references' {
    It 'resolves a custom-only reference into stable inventory aliases without mutating its caller' {
        $c=New-ReferenceConfig;$credential=New-ReferenceCredential 'HOST\CustomAdmin'
        $map=@{CustomHostAdministrator=$credential}
        $r=& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASCredentialMap $c $m} $c $map
        $r.Keys.Count|Should -Be 3
        [object]::ReferenceEquals($r.pvwa,$credential)|Should -BeTrue
        [object]::ReferenceEquals($r.pam01,$credential)|Should -BeTrue
        $map.Keys.Count|Should -Be 1
        $inv=& (Get-Module PASeasyInstall.Core) {param($c,$m) New-PASRuntimeInventory $c unused -SkipMediaHash -CredentialMap $m} $c $map
        $inv.Targets.pvwa.CredentialRef|Should -BeExactly pvwa
        $inv.Values.Components.pvwa.ManagementUser|Should -BeExactly 'HOST\CustomAdmin'
    }
    It 'keeps explicit component overrides and consistent host-ID precedence across host and component consumers' {
        $c=New-ReferenceConfig
        $c.components+=@{id='cpm';type='CPM';host='pam01';variant='Standard';options=@{}}
        $map=@{pvwa=(New-ReferenceCredential 'HOST\ComponentAdmin');CustomHostAdministrator=(New-ReferenceCredential 'HOST\ReferenceAdmin');pam01=(New-ReferenceCredential 'HOST\LegacyHostAdmin')}
        $r=& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASCredentialMap $c $m} $c $map
        $r.pvwa.UserName|Should -BeExactly 'HOST\ComponentAdmin'
        $r.cpm.UserName|Should -BeExactly 'HOST\LegacyHostAdmin'
        $r.pam01.UserName|Should -BeExactly 'HOST\LegacyHostAdmin'
        $map.ContainsKey('cpm')|Should -BeFalse
        $selected=& (Get-Module PASeasyInstall.Core) {param($c,$m) Get-PASHostCredential $c $m pam01 cpm} $c $map
        $selected.UserName|Should -BeExactly $r.cpm.UserName
    }
    It 'retains host-ID maps used by the native GUI when the custom alias is not supplied' {
        $c=New-ReferenceConfig;$map=@{pam01=(New-ReferenceCredential 'HOST\GUIAdmin')}
        $r=& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASCredentialMap $c $m} $c $map
        $r.pvwa.UserName|Should -BeExactly 'HOST\GUIAdmin'
    }
    It 'supports the original host-ID contract with no credentialRef property' {
        $c=New-ReferenceConfig;$c.hosts.pam01.Remove('credentialRef')
        $map=@{pam01=(New-ReferenceCredential 'HOST\OriginalAdmin')}
        $r=& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASCredentialMap $c $m} $c $map
        $r.pvwa.UserName|Should -BeExactly 'HOST\OriginalAdmin'
        (Test-PASConfiguration -Configuration $c).Valid|Should -BeTrue
    }
    It 'does not select a fallback after an explicitly supplied reference has the wrong type' {
        $c=New-ReferenceConfig;$map=@{CustomHostAdministrator='not a credential'}
        {& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASCredentialMap $c $m} $c $map}|Should -Throw '*CustomHostAdministrator*PSCredential*'
    }
    It 'does not bypass an invalid direct host override by choosing a lower-priority reference' {
        $c=New-ReferenceConfig;$map=@{pam01='not a credential';CustomHostAdministrator=(New-ReferenceCredential 'HOST\Fallback')}
        {& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASCredentialMap $c $m} $c $map}|Should -Throw '*pam01*PSCredential*'
    }
    It 'does not invent credentials or change an explicit domain transition credential' {
        $c=New-ReferenceConfig;$transition=New-ReferenceCredential 'DOMAIN\Administrator'
        $map=@{'ad-domain'=$transition}
        $r=& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASCredentialMap $c $m} $c $map
        $r.Keys.Count|Should -Be 1
        [object]::ReferenceEquals($r['ad-domain'],$transition)|Should -BeTrue
    }
    It 'ignores unused host records while supplying a join-only host alias' {
        $c=New-ReferenceConfig;$c.components=@();$c.activeDirectory.mode='Existing';$c.activeDirectory.join=@('pam01')
        $c.hosts.vault01.credentialRef=17
        $map=@{CustomHostAdministrator=(New-ReferenceCredential 'HOST\JoinAdmin')}
        $r=& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASCredentialMap $c $m} $c $map
        $r.pam01.UserName|Should -BeExactly 'HOST\JoinAdmin'
        $r.Keys.Count|Should -Be 2
    }
    It 'rejects malformed selected credentialRef values through public configuration validation' -TestCases @(@{Value=''},@{Value='  '},@{Value=$null},@{Value=17},@{Value=@{nested='wrong'}}) {
        param($Value)
        $c=New-ReferenceConfig;$c.hosts.pam01.credentialRef=$Value
        $result=Test-PASConfiguration -Configuration $c
        $result.Valid|Should -BeFalse
        ($result.Issues -join '; ')|Should -Match 'credentialRef must be a nonempty string'
    }
    It 'uses the custom reference in the public read-only diagnostics command' {
        $c=New-ReferenceConfig;$path=Join-Path $TestDrive 'diagnostic.json'
        $c|ConvertTo-Json -Depth 50|Set-Content $path -Encoding UTF8
        Mock Get-PASConnection -ModuleName PASeasyInstall.Core {New-MockObject -Type System.Management.Automation.Runspaces.PSSession}
        Mock Invoke-Command -ModuleName PASeasyInstall.Core {[pscustomobject]@{Count=1;Running=1;Names=@('CyberArk Scheduled Tasks')}}
        Mock Remove-PSSession -ModuleName PASeasyInstall.Core {}
        $r=@(Get-PASComponentStatus -Config $path -CredentialMap @{CustomHostAdministrator=(New-ReferenceCredential 'HOST\DiagnosticAdmin')})
        $r.Count|Should -Be 1
        $r[0].Reachable|Should -BeTrue
        $r[0].Verification|Should -BeExactly ServiceProbeOnly
        Should -Invoke Get-PASConnection -ModuleName PASeasyInstall.Core -Times 1 -Exactly -ParameterFilter {$Credentials.pvwa.UserName -eq 'HOST\DiagnosticAdmin' -and $Target.CredentialRef -eq 'pvwa'}
    }
}
Describe 'Vault role secret references' {
    It 'validates the exact execution map once even when configured references cross canonical role names' {
        $c=New-PASConfigurationTemplate -Template Vault -Path (Join-Path $TestDrive 'not-written-quote.json') -WhatIf
        $c.vault.secretRef='VaultMaster';$c.vault.masterSecretRef='ChosenMaster'
        $map=@{VaultMaster=(ConvertTo-SecureString ('Synthetic'+[char]34+'Invalid') -AsPlainText -Force);ChosenMaster=(ConvertTo-SecureString 'SyntheticValid' -AsPlainText -Force)}
        {& (Get-Module PASeasyInstall.Core) {param($c,$m) Assert-PASVaultInstallationSecrets $c $m} $c $map}|Should -Throw '*VaultAdmin requires printable ASCII*'
        $resolved=& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASSecretMap $c $m} $c $map
        {& (Get-Module PASeasyInstall.Core) {param($c,$m) Assert-PASVaultInstallationSecrets $c $m -ReferencesResolved} $c $resolved}|Should -Throw '*VaultAdmin requires printable ASCII*'
        [object]::ReferenceEquals($resolved.VaultAdmin,$map.VaultMaster)|Should -BeTrue
    }
    It 'does not fill a missing required role through an alias introduced by resolution' {
        $c=New-PASConfigurationTemplate -Template Vault -Path (Join-Path $TestDrive 'not-written-chain.json') -WhatIf
        $c.vault.secretRef='ChosenAdmin';$c.vault.masterSecretRef='VaultAdmin'
        $map=@{ChosenAdmin=(ConvertTo-SecureString 'SyntheticOnly' -AsPlainText -Force)}
        $resolved=& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASSecretMap $c $m} $c $map
        {& (Get-Module PASeasyInstall.Core) {param($c,$m) Assert-PASVaultInstallationSecrets $c $m -ReferencesResolved} $c $resolved}|Should -Throw '*VaultMaster SecureString is required*'
    }
    It 'admits custom-only installation secrets without changing the caller map' {
        $c=New-PASConfigurationTemplate -Template VaultDR -Path (Join-Path $TestDrive 'vault-not-written.json') -WhatIf
        $c.vault.secretRef='ChosenAdmin';$c.vault.masterSecretRef='ChosenMaster';$c.vault.drSecretRef='ChosenDR'
        $map=@{ChosenAdmin=(ConvertTo-SecureString 'SyntheticAdminOnly' -AsPlainText -Force);ChosenMaster=(ConvertTo-SecureString 'SyntheticMasterOnly' -AsPlainText -Force);ChosenDR=(ConvertTo-SecureString 'SyntheticDROnly' -AsPlainText -Force)}
        $r=& (Get-Module PASeasyInstall.Core) {param($c,$m) Assert-PASVaultInstallationSecrets $c $m; Resolve-PASSecretMap $c $m} $c $map
        foreach($pair in @(@('VaultAdmin','ChosenAdmin'),@('VaultMaster','ChosenMaster'),@('DRPassword','ChosenDR'))){[object]::ReferenceEquals($r[$pair[0]],$map[$pair[1]])|Should -BeTrue}
        $map.Keys.Count|Should -Be 3
    }
    It 'uses the explicitly configured secret before a legacy canonical fallback' {
        $c=New-ReferenceConfig;$c.vault.secretRef='ChosenAdmin'
        $chosen=ConvertTo-SecureString 'ChosenSynthetic' -AsPlainText -Force
        $map=@{ChosenAdmin=$chosen;VaultAdmin=(ConvertTo-SecureString 'LegacySynthetic' -AsPlainText -Force)}
        $r=& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASSecretMap $c $m} $c $map
        [object]::ReferenceEquals($r.VaultAdmin,$chosen)|Should -BeTrue
        [object]::ReferenceEquals($map.VaultAdmin,$chosen)|Should -BeFalse
    }
    It 'retains canonical role names supplied by the native GUI' {
        $c=New-ReferenceConfig;$c.vault.secretRef='ChosenAdmin'
        $secret=ConvertTo-SecureString 'SyntheticOnly' -AsPlainText -Force
        $r=& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASSecretMap $c $m} $c @{VaultAdmin=$secret}
        [object]::ReferenceEquals($r.VaultAdmin,$secret)|Should -BeTrue
    }
    It 'refuses a wrong-type explicit secret instead of quietly using another password' {
        $c=New-ReferenceConfig;$c.vault.secretRef='ChosenAdmin'
        {& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASSecretMap $c $m} $c @{ChosenAdmin='unprotected';VaultAdmin=(ConvertTo-SecureString 'SyntheticOnly' -AsPlainText -Force)}}|Should -Throw '*ChosenAdmin*SecureString*'
    }
    It 'rejects empty configured vault references during public validation' -TestCases @(@{Field='secretRef'},@{Field='masterSecretRef'},@{Field='drSecretRef'}) {
        param($Field)
        $c=New-ReferenceConfig;$c.vault[$Field]=' '
        $r=Test-PASConfiguration -Configuration $c
        $r.Valid|Should -BeFalse
        ($r.Issues -join '; ')|Should -Match ($Field+' must be a nonempty string')
    }
}
Describe 'Credential alias namespace admission' {
    It 'rejects a component ID that names another selected host before diagnostic authentication' {
        $c=New-ReferenceConfig
        $c.hosts.alpha=$c.hosts.pam01.Clone();$c.hosts.beta=$c.hosts.pam01.Clone();$c.hosts.beta.address='192.0.2.14'
        $c.components=@(@{id='alpha';type='PVWA';host='beta';options=@{}},@{id='one';type='CPM';host='alpha';options=@{}})
        $r=Test-PASConfiguration -Configuration $c
        $r.Valid|Should -BeFalse
        ($r.Issues -join '; ')|Should -Match 'different host.*credential key'
        $path=Join-Path $TestDrive 'collision.json';$c|ConvertTo-Json -Depth 50|Set-Content $path -Encoding UTF8
        Mock Get-PASConnection -ModuleName PASeasyInstall.Core {throw 'Unexpected target authentication'}
        {Get-PASComponentStatus -Config $path}|Should -Throw '*different host*credential key*'
        Should -Invoke Get-PASConnection -ModuleName PASeasyInstall.Core -Times 0 -Exactly
    }
    It 'reserves native Vault role aliases and the selected AD transition alias' {
        $v=New-PASConfigurationTemplate -Template Vault -Path (Join-Path $TestDrive 'not-written-reserved.json') -WhatIf
        $v.components+=@{id='primaryadmin';type='PVWA';host='pam01';options=@{}}
        $r=Test-PASConfiguration -Configuration $v
        $r.Valid|Should -BeFalse
        ($r.Issues -join '; ')|Should -Match 'reserved runtime credential alias'
        $a=New-PASConfigurationTemplate -Template ADOnly -Path (Join-Path $TestDrive 'not-written-adalias.json') -WhatIf
        $a.components+=@{id='ad-domain';type='PVWA';host='pam01';options=@{}}
        $r=Test-PASConfiguration -Configuration $a
        $r.Valid|Should -BeFalse
        ($r.Issues -join '; ')|Should -Match 'reserved runtime credential alias'
    }
    It 'keeps a component and its own host sharing one ID valid' {
        $c=New-ReferenceConfig;$c.components[0].id='pam01'
        (Test-PASConfiguration -Configuration $c).Valid|Should -BeTrue
    }
    It 'includes the existing PTA primary management host in namespace admission' {
        $c=New-ReferenceConfig
        $c.hosts.primary=$c.hosts.vault01.Clone();$c.vault.managementHost='primary'
        $c.components=@(@{id='primary';type='PVWA';host='pam01';options=@{}},@{id='pta500';type='PTA';host='pta01';options=@{}})
        $r=Test-PASConfiguration -Configuration $c
        $r.Valid|Should -BeFalse
        ($r.Issues -join '; ')|Should -Match 'different host.*credential key'
    }
    It 'binds a dedicated Vault component override consistently to its native role and host aliases' {
        $c=New-PASConfigurationTemplate -Template Vault -Path (Join-Path $TestDrive 'not-written-vaultcred.json') -WhatIf
        $map=@{vault=(New-ReferenceCredential 'VAULT\ComponentAdmin');vault01=(New-ReferenceCredential 'VAULT\HostAdmin')}
        $r=& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASCredentialMap $c $m} $c $map
        foreach($key in @('vault','vault01','PrimaryAdmin')){$r[$key].UserName|Should -BeExactly 'VAULT\ComponentAdmin'}
        $map.vault01.UserName|Should -BeExactly 'VAULT\HostAdmin'
        $map.ContainsKey('PrimaryAdmin')|Should -BeFalse
    }
    It 'preserves the legacy explicit native Vault role override across diagnostics and management' {
        $c=New-PASConfigurationTemplate -Template VaultDR -Path (Join-Path $TestDrive 'not-written-rolecred.json') -WhatIf
        $c.hosts.vault01.credentialRef='SharedHostRef'
        $map=@{PrimaryAdmin=(New-ReferenceCredential 'VAULT\RoleAdmin');vault=(New-ReferenceCredential 'VAULT\ComponentAdmin');SharedHostRef=(New-ReferenceCredential 'VAULT\NamedAdmin');DRAdmin=(New-ReferenceCredential 'DR\RoleAdmin')}
        $r=& (Get-Module PASeasyInstall.Core) {param($c,$m) Resolve-PASCredentialMap $c $m} $c $map
        foreach($key in @('vault','vault01','PrimaryAdmin')){$r[$key].UserName|Should -BeExactly 'VAULT\RoleAdmin'}
        foreach($key in @('dr','dr01','DRAdmin')){$r[$key].UserName|Should -BeExactly 'DR\RoleAdmin'}
        $inv=& (Get-Module PASeasyInstall.Core) {param($c,$m) New-PASRuntimeInventory $c unused -SkipMediaHash -CredentialMap $m} $c $map
        $inv.Values.Components.vault.ManagementUser|Should -BeExactly 'VAULT\RoleAdmin'
        $inv.Values.Components.dr.ManagementUser|Should -BeExactly 'DR\RoleAdmin'
    }
}
