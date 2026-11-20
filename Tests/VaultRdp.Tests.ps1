BeforeAll {
    $repo=Split-Path -Parent $PSScriptRoot
    . (Join-Path $repo 'PASeasyInstall/Recipes/Vault/Tasks/Common/VaultRdp.ps1')
    $hardenCode=Get-Content (Join-Path $repo 'PASeasyInstall/Recipes/Vault/Tasks/Vault/Harden-Vault.ps1') -Raw
    # Dummy command definitions ensure no native NetSecurity call can escape fixtures.
    function Get-NetFirewallProfile {param($PolicyStore)}
    function Get-NetFirewallRule {param($PolicyStore,$Direction,$Action,$Name,[switch]$TracePolicyStore)}
    function Get-NetFirewallPortFilter {param([Parameter(ValueFromPipeline)]$AssociatedNetFirewallRule) process{}}
    function Get-NetFirewallServiceFilter {param([Parameter(ValueFromPipeline)]$AssociatedNetFirewallRule) process{}}
    function Get-NetFirewallAddressFilter {param([Parameter(ValueFromPipeline)]$AssociatedNetFirewallRule) process{}}
    function Disable-NetFirewallRule {param([Parameter(ValueFromPipeline)]$InputObject) process{}}
    function Remove-NetFirewallRule {param([Parameter(ValueFromPipeline)]$InputObject) process{}}
    function New-NetFirewallRule {param($PolicyStore,$Name,$DisplayName,$Group,$Direction,$Action,$Enabled,$Profile,$Protocol,$LocalPort,$RemoteAddress,$Service)}
    function New-RdpRule($Name='VendorRdp',$Protocol='TCP',$Ports='3389',$Service='Any',$Remote='Any',$Group='CYBERARK_RULE_INSTALLATION',$Profile='Any'){
        [pscustomobject]@{Name=$Name;DisplayName=$Name;Group=$Group;Profile=$Profile;Enabled='True';Direction='Inbound';Action='Allow';PolicyStoreSourceType='Local';Store='ActiveStore';Port=[pscustomobject]@{Protocol=$Protocol;LocalPort=$Ports};ServiceFilter=[pscustomobject]@{Service=$Service};Address=[pscustomobject]@{RemoteAddress=$Remote}}
    }
}
Describe 'Vault explicit RDP policy (isolated registry/firewall mocks only)' {
    BeforeEach {
        $settings=@{Hardening=@{AllowRDP=$false};Management=@{ControllerAddress='198.51.100.250'}}
        $script:RdpRules=@();$script:RdpRegistry=@{};$script:RdpPort=3389
        $script:RdpProfiles=@(foreach($name in @('Domain','Private','Public')){[pscustomobject]@{Name=$name;Enabled='True';DefaultInboundAction='Block'}})
        Mock Get-NetFirewallProfile {$script:RdpProfiles}
        Mock Get-CimInstance {param($Namespace,$ClassName)
            if($Namespace -ne 'Root/CIMV2/TerminalServices' -or $ClassName -ne 'Win32_TerminalServiceSetting'){throw 'Unexpected CIM query'}
            $local=$script:RdpRegistry['HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server']
            [pscustomobject]@{AllowTSConnections=[int](1-$local);PolicySourceAllowTSConnections=[uint32]0}
        }
        Mock Get-ItemProperty {param($LiteralPath,$Name) if($Name -eq 'PortNumber'){return [pscustomobject]@{PortNumber=$script:RdpPort}};[pscustomobject]@{fDenyTSConnections=$script:RdpRegistry[[string]$LiteralPath]}}
        Mock Test-Path {$true}
        Mock New-ItemProperty {param($LiteralPath,$Name,$Value) $script:RdpRegistry[[string]$LiteralPath]=[int]$Value}
        Mock Get-NetFirewallRule {
            param($PolicyStore,$Name)
            if($Name){
                foreach($r in @($script:RdpRules|Where-Object Name -EQ $Name)){
                    $copy=$r.PSObject.Copy();$copy.Store='PersistentStore';$copy|Add-Member NoteProperty Original $r;$copy
                }
            }else{$script:RdpRules}
        }
        Mock Get-NetFirewallPortFilter {param($AssociatedNetFirewallRule) $AssociatedNetFirewallRule.Port}
        Mock Get-NetFirewallServiceFilter {param($AssociatedNetFirewallRule) $AssociatedNetFirewallRule.ServiceFilter}
        Mock Get-NetFirewallAddressFilter {param($AssociatedNetFirewallRule) $AssociatedNetFirewallRule.Address}
        Mock Disable-NetFirewallRule {param($InputObject) if($InputObject.Store -ne 'PersistentStore'){throw 'Test requires explicit PersistentStore mutation'};$InputObject.Original.Enabled='False'}
        Mock Remove-NetFirewallRule {param($InputObject) $script:RdpRules=@($script:RdpRules|Where-Object {$_.Name -ne $InputObject.Name})}
        Mock New-NetFirewallRule {
            param($Name,$Protocol,$LocalPort,$RemoteAddress,$Service,$Group,$Profile)
            $script:RdpRules+=New-RdpRule $Name $Protocol ([string]$LocalPort) $Service $RemoteAddress $Group $Profile
        }
    }
    It 'default deny disables broad vendor-group TCP and UDP regardless of display/group/profile' {
        $script:RdpRules=@((New-RdpRule 'RDP TCP'),(New-RdpRule 'RDP UDP' 'UDP' '3389' 'Any' 'Any' 'CYBERARK_RULE_INSTALLATION' 'Domain'))
        Set-PASeasyVaultRdpPolicy $settings
        @($script:RdpRules|Where-Object Enabled -EQ True).Count|Should -Be 0
        Test-PASeasyVaultRdpPolicy $settings|Should -BeTrue
        @($script:RdpRegistry.Values|Where-Object {$_ -ne 1}).Count|Should -Be 0
    }
    It 'independent verification refuses vendor group bypass even with registry deny set' {
        Set-PASeasyVaultRdpPolicy $settings
        $script:RdpRules=@(New-RdpRule)
        {Test-PASeasyVaultRdpPolicy $settings}|Should -Throw '*remains enabled*'
    }
    It 'requires actual local and policy deny rather than only absent firewall rules' {
        Set-PASeasyVaultRdpPolicy $settings
        $script:RdpRegistry['HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server']=0
        {Test-PASeasyVaultRdpPolicy $settings}|Should -Throw '*deny value*'
    }
    It 'explicit allow replaces broad RDP with exactly controller-scoped TCP and UDP' {
        $settings.Hardening.AllowRDP=$true;$script:RdpRules=@(New-RdpRule)
        Set-PASeasyVaultRdpPolicy $settings
        Test-PASeasyVaultRdpPolicy $settings|Should -BeTrue
        @($script:RdpRules|Where-Object Enabled -EQ True).Count|Should -Be 2
        @($script:RdpRules|Where-Object Enabled -EQ True|Where-Object {$_.Address.RemoteAddress -ne '198.51.100.250'}).Count|Should -Be 0
    }
    It 'refuses malformed flags and non-single/unicast controller addresses before writes' {
        foreach($bad in @('false',0,$null)){$settings.Hardening.AllowRDP=$bad;{Set-PASeasyVaultRdpPolicy $settings}|Should -Throw '*Boolean*'}
        $settings.Hardening.AllowRDP=$true
        foreach($bad in @('Any','198.51.100.250/24','198.51.100.250,198.51.100.251','127.0.0.1','0.0.0.0','ff02::1')){$settings.Management.ControllerAddress=$bad;{Set-PASeasyVaultRdpPolicy $settings}|Should -Throw '*one unicast*'}
        Should -Invoke New-ItemProperty -Times 0
    }
    It 'refuses unsupported listener ports before writes' {
        $script:RdpPort=3390
        {Set-PASeasyVaultRdpPolicy $settings}|Should -Throw '*unsupported*'
        Should -Invoke New-ItemProperty -Times 0
    }
    It 'fails closed for a range spanning RDP without disabling unrelated Vault or WinRM access' {
        $script:RdpRules=@(New-RdpRule 'Mixed' 'TCP' '1858-5986')
        {Set-PASeasyVaultRdpPolicy $settings}|Should -Throw '*range includes RDP*'
        Should -Invoke Disable-NetFirewallRule -Times 0
        @($script:RdpRegistry.Values|Where-Object {$_ -ne 1}).Count|Should -Be 0
    }
    It 'fails closed for Any protocol/port/service instead of silently treating it as a Vault rule' {
        $script:RdpRules=@(New-RdpRule 'CYBERARK' 'Any' 'Any')
        {Set-PASeasyVaultRdpPolicy $settings}|Should -Throw '*Unrestricted*'
        Should -Invoke Disable-NetFirewallRule -Times 0
    }
    It 'disables TermService Any-port rules without trusting their name' {
        $script:RdpRules=@(New-RdpRule 'Renamed' 'TCP' 'Any' 'TermService')
        Set-PASeasyVaultRdpPolicy $settings
        $script:RdpRules[0].Enabled|Should -BeExactly False
    }
    It 'preserves WinRM and Vault rules while denying numeric protocol 3389 RDP' {
        $script:RdpRules=@((New-RdpRule 'Vault' 'TCP' '1858'),(New-RdpRule 'WinRM' 'TCP' '5986'),(New-RdpRule 'RDP' '6' '3389'))
        Set-PASeasyVaultRdpPolicy $settings
        $script:RdpRules[0].Enabled|Should -BeExactly True
        $script:RdpRules[1].Enabled|Should -BeExactly True
        $script:RdpRules[2].Enabled|Should -BeExactly False
    }
    It 'rejects mixed ports and dynamic aliases rather than disabling unrelated allow rules' {
        foreach($ports in @(@('3389','5986'),'RPC')){
            $r=New-RdpRule;$r.Port.LocalPort=$ports
            {Get-PASeasyVaultRdpRuleClass $r $r.Port $r.ServiceFilter}|Should -Throw
        }
    }
    It 'detects stale-profile RDP activation after a formerly successful deny check' {
        Set-PASeasyVaultRdpPolicy $settings
        $r=New-RdpRule 'DormantDomain' 'UDP' '3389' 'Any' 'Any' 'CYBERARK' 'Domain';$r.Enabled='False';$script:RdpRules=@($r)
        Test-PASeasyVaultRdpPolicy $settings|Should -BeTrue
        $r.Enabled='True'
        {Test-PASeasyVaultRdpPolicy $settings}|Should -Throw '*remains enabled*'
    }
    It 'disables explicit3389 even with Any protocol or a different service tag' {
        $script:RdpRules=@((New-RdpRule 'AllProtocols' 'Any' '3389'),(New-RdpRule 'Tagged' 'UDP' '3389' 'OtherService'))
        Set-PASeasyVaultRdpPolicy $settings
        @($script:RdpRules|Where-Object Enabled -EQ True).Count|Should -Be 0
    }
    It 'preserves a portAny WinRM-specific rule without granting TermService access' {
        $script:RdpRules=@(New-RdpRule 'WinRMService' 'TCP' 'Any' 'WinRM')
        Set-PASeasyVaultRdpPolicy $settings
        $script:RdpRules[0].Enabled|Should -BeExactly True
    }
    It 'refuses GPO sourced RDP while denying registry without mutating any firewall rule' {
        $r=New-RdpRule;$r.PolicyStoreSourceType='GroupPolicy';$script:RdpRules=@($r)
        {Set-PASeasyVaultRdpPolicy $settings}|Should -Throw '*outside writable*'
        Should -Invoke Disable-NetFirewallRule -Times 0
        @($script:RdpRegistry.Values|Where-Object {$_ -ne 1}).Count|Should -Be 0
    }
    It 'refuses missing local RDP identity instead of mutating an ambiguous aggregate instance' {
        $script:RdpRules=@(New-RdpRule)
        Mock Get-NetFirewallRule {$null} -ParameterFilter {$PolicyStore -eq 'PersistentStore'}
        {Set-PASeasyVaultRdpPolicy $settings}|Should -Throw '*identified uniquely*'
        Should -Invoke Disable-NetFirewallRule -Times 0
    }
    It 'refuses disabled or default-allow firewall profiles before activating RDP' {
        $settings.Hardening.AllowRDP=$true
        $script:RdpProfiles[0].Enabled='False'
        {Set-PASeasyVaultRdpPolicy $settings}|Should -Throw '*firewall*'
        @($script:RdpRegistry.Values|Where-Object {$_ -ne 1}).Count|Should -Be 0
        $script:RdpProfiles[0].Enabled='True';$script:RdpProfiles[1].DefaultInboundAction='Allow'
        {Test-PASeasyVaultRdpPolicy $settings}|Should -Throw '*firewall*'
    }
    It 'rolls back both deny values when post-activation verification fails' {
        $settings.Hardening.AllowRDP=$true
        Mock Test-PASeasyVaultRdpPolicy {throw 'Synthetic scope race after activation'}
        {Set-PASeasyVaultRdpPolicy $settings}|Should -Throw '*returned to deny*'
        $script:RdpRegistry.Count|Should -Be 2
        @($script:RdpRegistry.Values|Where-Object {$_ -ne 1}).Count|Should -Be 0
        Should -Invoke New-ItemProperty -ParameterFilter {$Value -eq 0} -Times 2
    }
    It 'rejects missing or contradictory effective WMI policy without pretending registry is effective proof' {
        Set-PASeasyVaultRdpPolicy $settings
        Mock Get-CimInstance {[pscustomobject]@{AllowTSConnections=[uint32]1;PolicySourceAllowTSConnections=[uint32]1}}
        {Test-PASeasyVaultRdpPolicy $settings}|Should -Throw '*contradicts*'
        Mock Get-CimInstance {throw 'Provider unavailable'}
        {Test-PASeasyVaultRdpPolicy $settings}|Should -Throw '*NotTested*'
    }
    It 'attempts both containment writes even if the first policy write fails' {
        Mock New-ItemProperty {throw 'Synthetic policy write refusal'} -ParameterFilter {$LiteralPath -like '*Policies*'}
        {Set-PASeasyVaultRdpDeny}|Should -Throw '*both registry writes*'
        Should -Invoke New-ItemProperty -ParameterFilter {$LiteralPath -like '*Policies*'} -Times 1
        Should -Invoke New-ItemProperty -ParameterFilter {$LiteralPath -like '*SYSTEM*'} -Times 1
        $script:RdpRegistry['HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server']|Should -Be 1
    }
    It 'actual hardener recipe contains before native launch and restores deny on native failure' {
        $settings.InstallRoot='C:\SyntheticVault';$settings.AutomationRoot='C:\SyntheticAutomation';$settings.Hardening.Architecture='StandardVault'
        Mock Test-Path {param($LiteralPath) return ($LiteralPath -like '*CAVaultHarden.exe' -or $LiteralPath -like 'HKLM:*')}
        Mock Start-Process {
            @($script:RdpRegistry.Values|Where-Object {$_ -ne 1}).Count|Should -Be 0
            $script:RdpRegistry.Count|Should -Be 2
            # Simulate the vendor re-enabling registry RDP before failing/missing log.
            foreach($key in @($script:RdpRegistry.Keys)){$script:RdpRegistry[$key]=0}
            [pscustomobject]@{ExitCode=9}
        }
        {& ([scriptblock]::Create($hardenCode)) -Settings $settings}|Should -Throw '*no log*'
        Should -Invoke Start-Process -Times 1
        $script:RdpRegistry.Count|Should -Be 2
        @($script:RdpRegistry.Values|Where-Object {$_ -ne 1}).Count|Should -Be 0
        Should -Invoke New-ItemProperty -ParameterFilter {$Value -eq 1} -Times 4
    }
    It 'rejects broadened opt-in scope after activation' {
        $settings.Hardening.AllowRDP=$true;Set-PASeasyVaultRdpPolicy $settings
        $r=@($script:RdpRules|Where-Object Enabled -EQ True)[0];$r.Address.RemoteAddress='Any'
        {Test-PASeasyVaultRdpPolicy $settings}|Should -Throw '*not exactly scoped*'
    }
}
