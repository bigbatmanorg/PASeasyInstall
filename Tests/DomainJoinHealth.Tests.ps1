BeforeAll {
    $join=Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.AD/Recipes/ActiveDirectory/Join-Task.ps1'
}
Describe 'Domain join target eligibility and independent trust validation' {
    BeforeEach {
        Mock Get-CimInstance {[pscustomobject]@{PartOfDomain=$true;Domain='paeasy.test';DomainRole=3}}
        Mock Get-Service {}
        Mock Test-ComputerSecureChannel {$true}
        Mock Resolve-DnsName {[pscustomobject]@{Type='SRV';NameTarget='dc.paeasy.test';Port=389}}
        Mock Add-Computer {throw 'Unexpected join mutation'}
    }
    It 'verifies a healthy joined member without another join' {
        $result=& $join -Stage Verify -Settings @{Domain='paeasy.test'}
        $result.Changed | Should -BeFalse
        $result.Message | Should -Match 'secure channel'
        Should -Invoke Test-ComputerSecureChannel -Exactly 1
        Should -Invoke Add-Computer -Exactly 0
    }
    It 'refuses broken machine trust despite matching domain membership' {
        Mock Test-ComputerSecureChannel {$false}
        {& $join -Stage Verify -Settings @{Domain='paeasy.test'}} | Should -Throw '*secure channel is broken*'
        Should -Invoke Add-Computer -Exactly 0
    }
    It 'never treats a domain controller as an eligible member join target' {
        Mock Get-CimInstance {[pscustomobject]@{PartOfDomain=$true;Domain='paeasy.test';DomainRole=5}}
        {& $join -Stage Join -Settings @{Domain='paeasy.test'}} | Should -Throw '*domain controller*'
        Should -Invoke Add-Computer -Exactly 0
    }
    It 'refuses existing Vault software even if configuration selected a different component' {
        Mock Get-CimInstance {[pscustomobject]@{PartOfDomain=$false;Domain='WORKGROUP';DomainRole=2}}
        Mock Get-Service {[pscustomobject]@{Name='PrivateArk Server'}}
        {& $join -Stage Join -Settings @{Domain='paeasy.test'}} | Should -Throw '*Vault and DR hosts must remain workgroup*'
        Should -Invoke Add-Computer -Exactly 0
    }
    It 'requires LDAP SRV records after joining' {
        Mock Resolve-DnsName {@()}
        {& $join -Stage Verify -Settings @{Domain='paeasy.test'}} | Should -Throw '*LDAP SRV records*'
        Should -Invoke Add-Computer -Exactly 0
    }
}

Describe 'Explicit domain DNS and durable join submission' {
    BeforeAll {
        $joinState=Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.AD/Recipes/ActiveDirectory/Join-State.ps1'
        $joinVerify=Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.AD/Recipes/ActiveDirectory/Join-Verify.ps1'
        . $joinState
    }
    BeforeEach {
        $boot=[datetime]'2026-11-16T22:00:00Z'
        $settings=@{Domain='paeasy.test';JoinUser='PAEASY\Administrator';DnsServers=@('192.0.2.161');StageRoot=(Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))}
        Mock Get-CimInstance {
            param($ClassName)
            if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{LastBootUpTime=$boot}}
            return [pscustomobject]@{PartOfDomain=$false;Domain='WORKGROUP';DomainRole=2}
        }
        Mock Get-Service {}
        Mock Resolve-DnsName {[pscustomobject]@{Type='SRV';NameTarget='dc.paeasy.test';Port=389}}
        Mock Get-NetIPConfiguration {[pscustomobject]@{InterfaceIndex=4;IPv4DefaultGateway=@('192.0.2.1');NetAdapter=[pscustomobject]@{Status='Up'}}}
        Mock Get-DnsClientServerAddress {[pscustomobject]@{ServerAddresses=@('192.0.2.1')}}
        Mock Set-DnsClientServerAddress {}
        Mock Clear-DnsClientCache {}
        Mock Get-Acl {
            $acl=[Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
            return $acl
        }
        Mock Set-Acl {}
        Mock Add-Computer {[pscustomobject]@{HasSucceeded=$true}}
    }
    It 'sets explicit DNS on the sole active routed adapter before resolving AD' {
        & $join -Stage Check -Settings $settings
        Should -Invoke Set-DnsClientServerAddress -Exactly 1 -ParameterFilter {$InterfaceIndex -eq 4 -and $ServerAddresses -contains '192.0.2.161'}
        Should -Invoke Add-Computer -Exactly 0
    }
    It 'rejects missing DNS without mutating host networking' {
        $settings.Remove('DnsServers')
        {& $join -Stage Check -Settings $settings} | Should -Throw '*Explicit AD DNS*'
        Should -Invoke Set-DnsClientServerAddress -Exactly 0
    }
    It 'rejects IPv6 DNS and ambiguous adapters before join' {
        $settings.DnsServers=@('::1')
        {& $join -Stage Check -Settings $settings} | Should -Throw '*valid IPv4*'
        $settings.DnsServers=@('192.0.2.161')
        Mock Get-NetIPConfiguration {@([pscustomobject]@{InterfaceIndex=4;IPv4DefaultGateway=@('x');NetAdapter=[pscustomobject]@{Status='Up'}},[pscustomobject]@{InterfaceIndex=5;IPv4DefaultGateway=@('y');NetAdapter=[pscustomobject]@{Status='Up'}})}
        {& $join -Stage Join -Settings $settings -DomainPassword 'synthetic-test-only'} | Should -Throw '*one active default-route adapter*'
        Should -Invoke Add-Computer -Exactly 0
    }
    It 'accepts confirmed same-boot submission then refuses it as final health' {
        & $join -Stage Join -Settings $settings -DomainPassword 'synthetic-test-only'
        (& $joinVerify -Stage Join -Settings $settings).Passed | Should -BeTrue
        (& $joinVerify -Stage Verify -Settings $settings).Passed | Should -BeFalse
        & $join -Stage Join -Settings $settings -DomainPassword 'synthetic-test-only'
        Should -Invoke Add-Computer -Exactly 1 -ParameterFilter {$PassThru}
        $record=Get-Content (Join-Path $settings.StageRoot 'domain-join.json') -Raw
        $record | Should -Not -Match 'synthetic-test-only'
    }
    It 'refuses native join without explicit boolean successful output' {
        Mock Add-Computer {[pscustomobject]@{HasSucceeded='true'}}
        {& $join -Stage Join -Settings $settings -DomainPassword 'synthetic-test-only'} | Should -Throw '*did not confirm*'
        (Get-Content (Join-Path $settings.StageRoot 'domain-join.json') -Raw | ConvertFrom-Json).hasSucceeded | Should -BeFalse
        (& $joinVerify -Stage Join -Settings $settings).Passed | Should -BeFalse
        {& $join -Stage Join -Settings $settings -DomainPassword 'synthetic-test-only'} | Should -Throw '*reconcile target*'
        Should -Invoke Add-Computer -Exactly 1
    }
    It 'refuses stale-boot pending records without repeating join' {
        & $join -Stage Join -Settings $settings -DomainPassword 'synthetic-test-only'
        Mock Get-CimInstance {
            param($ClassName)
            if($ClassName -eq 'Win32_OperatingSystem'){return [pscustomobject]@{LastBootUpTime=$boot.AddMinutes(1)}}
            [pscustomobject]@{PartOfDomain=$false;Domain='WORKGROUP';DomainRole=2}
        }
        (& $joinVerify -Stage Join -Settings $settings).Passed | Should -BeFalse
        {& $join -Stage Join -Settings $settings -DomainPassword 'synthetic-test-only'} | Should -Throw '*reconcile target*'
        Should -Invoke Add-Computer -Exactly 1
    }
    It 'rejects wrong-domain and string-success records as join evidence' {
        & $join -Stage Join -Settings $settings -DomainPassword 'synthetic-test-only'
        $path=Join-Path $settings.StageRoot 'domain-join.json'
        $record=Get-Content $path -Raw | ConvertFrom-Json
        $record.domain='other.test';$record | ConvertTo-Json | Set-Content $path
        (& $joinVerify -Stage Join -Settings $settings).Passed | Should -BeFalse
        $record.domain='paeasy.test';$record.hasSucceeded='true';$record | ConvertTo-Json | Set-Content $path
        (& $joinVerify -Stage Join -Settings $settings).Passed | Should -BeFalse
        Should -Invoke Add-Computer -Exactly 1
    }
    It 'refuses a broadly writable checkpoint before another native join' {
        New-Item $settings.StageRoot -ItemType Directory | Out-Null
        Mock Get-Acl {
            $acl=[Security.AccessControl.DirectorySecurity]::new()
            $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.AccessControlType]::Allow))
            return $acl
        }
        # Marker exists, so its own broad DACL must be rejected during reconciliation.
        '{}' | Set-Content (Join-Path $settings.StageRoot 'domain-join.json')
        {& $join -Stage Join -Settings $settings -DomainPassword 'synthetic-test-only'} | Should -Throw '*untrusted writes*'
        Should -Invoke Add-Computer -Exactly 0
    }
    It 'honors an explicit active adapter without default-route guessing' {
        $settings.InterfaceIndex=7
        Mock Get-NetAdapter {[pscustomobject]@{InterfaceIndex=7;Status='Up'}}
        & $join -Stage Check -Settings $settings
        Should -Invoke Get-NetIPConfiguration -Exactly 0
        Should -Invoke Set-DnsClientServerAddress -Exactly 1 -ParameterFilter {$InterfaceIndex -eq 7}
    }

}
