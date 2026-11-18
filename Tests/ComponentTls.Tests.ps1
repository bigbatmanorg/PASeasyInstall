BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    . (Join-Path $root 'Modules/PASeasyInstall.PVWA/Recipes/WindowsComponent/PvwaTls.ps1')
    . (Join-Path $root 'Modules/PASeasyInstall.CPM/Recipes/WindowsComponent/CpmTls.ps1')
    function Get-WebBinding {param($Name,$Protocol)}
    function New-WebBinding {param($Name,$Protocol,$Port,$HostHeader,$SslFlags)}
    function Get-WebConfigurationProperty {param($PSPath,$Location,$Filter,$Name)}
    $unique=[guid]::NewGuid().ToString('N')
    $leaf=New-SelfSignedCertificate -DnsName ('tls-'+$unique+'.invalid') -CertStoreLocation Cert:\LocalMachine\My -FriendlyName ('PASeasy-unit-'+$unique) -KeyExportPolicy Exportable
    $ca=New-SelfSignedCertificate -Type Custom -Subject ('CN=PASeasy-unit-ca-'+$unique) -CertStoreLocation Cert:\LocalMachine\My -KeyUsage CertSign,CRLSign -TextExtension @('2.5.29.19={critical}{text}CA=true') -FriendlyName ('PASeasy-unit-ca-'+$unique)
}
AfterAll {
    foreach($c in @($leaf,$ca)){if($c){Remove-Item -LiteralPath ('Cert:\LocalMachine\My\'+$c.Thumbprint) -DeleteKey -Force}}
}
Describe 'PVWA TLS policy and independent binding gates' {
    BeforeEach {$settings=@{Id='tls-unit';StageRoot=$TestDrive;SecurityProfile='Secure';Options=@{pvwaUrl='https://web.test/PasswordVault';tlsCertificateThumbprint=('A'*40)}}}
    It 'requires an actual selected certificate for secure defaults' {
        $settings.Options.Remove('tlsCertificateThumbprint')
        {Get-PASeasyPvwaTlsPolicy $settings}|Should -Throw '*requires options.tlsCertificateThumbprint*'
        $settings.Options.createLabCertificate=$true
        {Get-PASeasyPvwaTlsPolicy $settings}|Should -Throw '*explicit Lab*'
    }
    It 'refuses malformed endpoints, thumbprints, ambiguous modes and Boolean lookalikes' {
        $settings.Options.pvwaUrl='http://web.test/PasswordVault'
        {Get-PASeasyPvwaTlsPolicy $settings}|Should -Throw '*HTTPS*'
        $settings.Options.pvwaUrl='https://user:password@web.test/PasswordVault'
        {Get-PASeasyPvwaTlsPolicy $settings}|Should -Throw '*HTTPS*'
        $settings.Options.pvwaUrl='https://web.test/PasswordVault';$settings.Options.tlsCertificateThumbprint='bad'
        {Get-PASeasyPvwaTlsPolicy $settings}|Should -Throw '*Thumbprint*'
        $settings.Options.tlsCertificateThumbprint='A'*40;$settings.SecurityProfile='Lab';$settings.Options.createLabCertificate=$true
        {Get-PASeasyPvwaTlsPolicy $settings}|Should -Throw '*not both*'
        $settings.Options.createLabCertificate='false'
        {Get-PASeasyPvwaTlsPolicy $settings}|Should -Throw '*Boolean*'
    }
    It 'allows explicit pending Lab creation without generating certificates in preflight' {
        $settings.SecurityProfile='Lab';$settings.Options.Remove('tlsCertificateThumbprint');$settings.Options.createLabCertificate=$true
        Mock Get-PASeasyPvwaCertificate {$null}
        Mock New-SelfSignedCertificate {throw 'must not mutate in preflight'}
        (Test-PASeasyPvwaTlsPreparation $settings).CertificatePending|Should -BeTrue
        Should -Invoke New-SelfSignedCertificate -Times 0
    }
    It 'rejects missing private keys, expired identities and absent ServerAuth before binding' {
        {Assert-PASeasyPvwaCertificate ([pscustomobject]@{HasPrivateKey=$false})}|Should -Throw '*private key*'
        $fake=[pscustomobject]@{HasPrivateKey=$true;NotBefore=[DateTime]::UtcNow.AddDays(-2);NotAfter=[DateTime]::UtcNow.AddDays(-1);EnhancedKeyUsageList=@()}
        {Assert-PASeasyPvwaCertificate $fake}|Should -Throw '*validity*'
        $fake.NotAfter=[DateTime]::UtcNow.AddDays(1)
        {Assert-PASeasyPvwaCertificate $fake}|Should -Throw '*Server Authentication*'
    }
    It 'binds the selected cert and writes a public checkpoint only after effective TLS validation' {
        $cert=[pscustomobject]@{Thumbprint=('A'*40);RawData=[byte[]](1,2,3)}
        Mock Get-PASeasyPvwaCertificate {$cert}
        Mock Assert-PASeasyPvwaCertificate {}
        Mock Import-Module {} -ParameterFilter {$Name -eq 'WebAdministration'}
        $script:bound=$null
        Mock Get-WebBinding {if($script:bound){$script:bound}}
        Mock New-WebBinding {
            $script:bound=[pscustomobject]@{bindingInformation='*:443:web.test';certificateHash='';certificateStoreName='My'}
            $script:bound|Add-Member ScriptMethod AddSslCertificate {param($thumb,$store)$this.certificateHash=$thumb;$this.certificateStoreName=$store}
        }
        Mock Get-WebConfigurationProperty {'Ssl'}
        Mock Test-PASeasyPvwaTlsTransport {@{Passed=$true}}
        $r=Invoke-PASeasyPvwaTls $settings
        $r.Transport.Passed|Should -BeTrue
        $r.Data.Metadata|Should -Match ('A'*40)
        $r.Data.Hash|Should -Match '^[A-F0-9]{64}$'
        Test-Path (Join-Path $TestDrive 'pvwa-tls.json')|Should -BeTrue
        Should -Invoke New-WebBinding -Times 1 -ParameterFilter {$SslFlags -eq 1 -and $HostHeader -eq 'web.test'}
        Should -Invoke Test-PASeasyPvwaTlsTransport -Times 1 -ParameterFilter {$ExpectedThumbprint -eq ('A'*40)}
    }
    It 'refuses to replace an unrelated existing HTTPS certificate' {
        Mock Get-PASeasyPvwaCertificate {@{Thumbprint=('A'*40)}}
        Mock Assert-PASeasyPvwaCertificate {}
        Mock Import-Module {} -ParameterFilter {$Name -eq 'WebAdministration'}
        Mock Get-WebBinding {@{bindingInformation='*:443:web.test';certificateHash=('B'*40);certificateStoreName='My'}}
        Mock New-WebBinding {}
        {Invoke-PASeasyPvwaTls $settings}|Should -Throw '*Refusing to replace*'
        Should -Invoke New-WebBinding -Times 0
    }
    It 'does not rebind an already correct endpoint during continuation' {
        Mock Get-PASeasyPvwaCertificate {@{Thumbprint=('A'*40);RawData=[byte[]](1,2,3)}}
        Mock Assert-PASeasyPvwaCertificate {}
        Mock Import-Module {} -ParameterFilter {$Name -eq 'WebAdministration'}
        Mock Get-WebBinding {
            $b=[pscustomobject]@{bindingInformation='*:443:web.test';certificateHash=('A'*40);certificateStoreName='My'}
            $b|Add-Member ScriptMethod AddSslCertificate {throw 'An existing correct binding must not be reset'}
            $b
        }
        Mock Get-WebConfigurationProperty {'Ssl'}
        Mock Test-PASeasyPvwaTlsTransport {@{Passed=$true}}
        (Invoke-PASeasyPvwaTls $settings).Transport.Passed|Should -BeTrue
    }
    It 'accepts the observed native Server2022 scalar string including additional SSL flags' {
        $p=Get-PASeasyPvwaTlsPolicy $settings
        Mock Get-WebBinding {@{bindingInformation='*:443:web.test';certificateHash=('A'*40);certificateStoreName='My'}}
        Mock Get-WebConfigurationProperty {'Ssl, SslNegotiateCert'}
        {Assert-PASeasyPvwaHttpsBinding $p @{Thumbprint=('A'*40)}}|Should -Not -Throw
    }
    It 'rejects misleading shapes and SSL-like tokens that do not require HTTPS' {
        $p=Get-PASeasyPvwaTlsPolicy $settings
        Mock Get-WebBinding {@{bindingInformation='*:443:web.test';certificateHash=('A'*40);certificateStoreName='My'}}
        Mock Get-WebConfigurationProperty {@{Value='Ssl'}}
        {Assert-PASeasyPvwaHttpsBinding $p @{Thumbprint=('A'*40)}}|Should -Throw '*unexpected value type*'
        Mock Get-WebConfigurationProperty {'Ssl128'}
        {Assert-PASeasyPvwaHttpsBinding $p @{Thumbprint=('A'*40)}}|Should -Throw '*require HTTPS*'
    }
    It 'does not accept a binding marker without effective required SSL' {
        $p=Get-PASeasyPvwaTlsPolicy $settings
        Mock Get-WebBinding {@{bindingInformation='*:443:web.test';certificateHash=('A'*40);certificateStoreName='My'}}
        Mock Get-WebConfigurationProperty {'None'}
        {Assert-PASeasyPvwaHttpsBinding $p @{Thumbprint=('A'*40)}}|Should -Throw '*require HTTPS*'
    }
}
Describe 'CPM frozen public trust certificates' {
    BeforeEach {
        $file=Join-Path $TestDrive 'trust.cer';$null=Export-Certificate -Cert $leaf -FilePath $file -Force
        $settings=@{SecurityProfile='Secure';PVWATrustCertificateTarget=$file;PVWATrustCertificateSHA256=(Get-FileHash $file).Hash;AllowPinnedLeafTrust=$false}
    }
    It 'rejects a leaf under Secure and requires an additional explicit Lab trust override' {
        {Get-PASeasyCpmTrustCertificate $settings}|Should -Throw '*explicit Lab*'
        $settings.SecurityProfile='Lab'
        {Get-PASeasyCpmTrustCertificate $settings}|Should -Throw '*explicit Lab*'
        $settings.AllowPinnedLeafTrust=$true
        $r=Get-PASeasyCpmTrustCertificate $settings
        try{$r.LabLeaf|Should -BeTrue;$r.Certificate.HasPrivateKey|Should -BeFalse}finally{$r.Certificate.Dispose()}
    }
    It 'accepts a pinned self-signed CA with signing usage under Secure' {
        $null=Export-Certificate -Cert $ca -FilePath $file -Force
        $settings.PVWATrustCertificateSHA256=(Get-FileHash $file).Hash
        $r=Get-PASeasyCpmTrustCertificate $settings
        try{$r.LabLeaf|Should -BeFalse;$r.Certificate.HasPrivateKey|Should -BeFalse}finally{$r.Certificate.Dispose()}
    }
    It 'rejects altered bytes and absent digest before certificate trust mutation' {
        $settings.PVWATrustCertificateSHA256='0'*64
        {Get-PASeasyCpmTrustCertificate $settings}|Should -Throw '*differs*'
        $settings.PVWATrustCertificateSHA256=''
        {Get-PASeasyCpmTrustCertificate $settings}|Should -Throw '*frozen SHA256*'
    }
    It 'refuses PFX even when the private container has the approved hash' {
        $pfx=Join-Path $TestDrive 'private.pfx'
        $null=Export-PfxCertificate -Cert $leaf -FilePath $pfx -Password (ConvertTo-SecureString 'SYNTHETIC_PFX_TEST' -AsPlainText -Force)
        $settings.PVWATrustCertificateTarget=$pfx;$settings.PVWATrustCertificateSHA256=(Get-FileHash $pfx).Hash
        {Get-PASeasyCpmTrustCertificate $settings}|Should -Throw '*never PFX*'
    }
    It 'never reports absent pinned roots as verified' {
        $settings.SecurityProfile='Lab';$settings.AllowPinnedLeafTrust=$true
        {Test-PASeasyCpmTls $settings}|Should -Throw '*not present*'
    }
}

Describe 'Actual TaskHost ConfigureTLS terminal contract' {
    It 'accepts the PVWA ConfigureTLS helper through materialized TaskHost code' {
        $helper=Join-Path $root 'Modules/PASeasyInstall.PVWA/Recipes/WindowsComponent/PvwaTls.ps1'
        $hostFile=Join-Path $root 'Modules/PASeasyInstall.Core/Private/Engine/Assets/TaskHost.ps1'
        $code=@'
[CmdletBinding()]param([hashtable]$Settings,[string]$Helper)
. $Helper
function Import-Module {}
function Get-PASeasyPvwaCertificate { [pscustomobject]@{Thumbprint=('A'*40);RawData=[byte[]](1,2,3)} }
function Assert-PASeasyPvwaCertificate {}
function Get-WebBinding {
 $b=[pscustomobject]@{bindingInformation='*:443:web.test';certificateHash=('A'*40);certificateStoreName='My'}
 $b|Add-Member ScriptMethod AddSslCertificate {param($thumb,$store)}
 $b
}
function Get-WebConfigurationProperty { 'Ssl' }
function Test-PASeasyPvwaTlsTransport { @{Passed=$true} }
Invoke-PASeasyPvwaTls -Settings $Settings
'@
        $settings=@{Id='host-contract';StageRoot=$TestDrive;SecurityProfile='Secure';Options=@{pvwaUrl='https://web.test/PasswordVault';tlsCertificateThumbprint=('A'*40)}}
        $r=& $hostFile -Code $code -Parameters @{Settings=$settings;Helper=$helper} -Contract Object
        $r.Ok|Should -BeTrue
        $r.Terminal.Data.Keys|Sort-Object|Should -Be @('Hash','Metadata')
        $r.Terminal.Data.Hash|Should -Match '^[A-F0-9]{64}$'
    }
    It 'accepts the CPM ConfigureTLS helper through materialized TaskHost code' {
        $helper=Join-Path $root 'Modules/PASeasyInstall.CPM/Recipes/WindowsComponent/CpmTls.ps1'
        $hostFile=Join-Path $root 'Modules/PASeasyInstall.Core/Private/Engine/Assets/TaskHost.ps1'
        $file=Join-Path $TestDrive 'host-ca.cer';$null=Export-Certificate -Cert $ca -FilePath $file
        $settings=@{SecurityProfile='Secure';PVWATrustCertificateTarget=$file;PVWATrustCertificateSHA256=(Get-FileHash $file).Hash}
        $code=@'
[CmdletBinding()]param([hashtable]$Settings,[string]$Helper)
. $Helper
function Add-PASeasyCpmTrustCertificate {}
function Test-PASeasyCpmTls { @{Passed=$true;Detail='Public CA fixture trust independently simulated'} }
Invoke-PASeasyCpmTls -Settings $Settings
'@
        $r=& $hostFile -Code $code -Parameters @{Settings=$settings;Helper=$helper} -Contract Object
        $r.Ok|Should -BeTrue
        $r.Terminal.Data.Keys|Sort-Object|Should -Be @('Hash','Metadata')
        $r.Terminal.Data.Hash|Should -BeExactly $settings.PVWATrustCertificateSHA256
    }
    It 'still rejects an arbitrary nested Data structure through actual TaskHost' {
        $hostFile=Join-Path $root 'Modules/PASeasyInstall.Core/Private/Engine/Assets/TaskHost.ps1'
        $r=& $hostFile -Code "[pscustomobject]@{Changed=`$true;Message='fixture';Data=@{Nested=@{Token='SYNTHETIC_UNSUPPORTED'}}}" -Parameters @{} -Contract Object
        $r.Ok|Should -BeFalse
        $r.Error|Should -BeExactly 'Task returned unsupported Data payload'
        $r.Terminal.Data|Should -BeNullOrEmpty
    }
}
