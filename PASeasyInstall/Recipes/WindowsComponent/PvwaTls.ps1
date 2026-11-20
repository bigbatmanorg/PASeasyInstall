# Certificate keys stay in the target machine store. No plaintext/PFX secret staging.
function Get-PASeasyPvwaTlsPolicy {
    param([hashtable]$Settings)
    $options = $Settings.Options
    if (-not $options) { $options = @{} }
    $url = if ($options.Contains('pvwaUrl')) { [string]$options.pvwaUrl }else { 'https://' + $env:COMPUTERNAME + '/PasswordVault' }
    $uri = $null
    if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or
        $uri.UserInfo -or
        $uri.Query -or
        $uri.Fragment -or
        $uri.AbsolutePath.Trim('/') -notmatch '^[A-Za-z0-9_-]+$') { throw 'PVWA requires an HTTPS pvwaUrl with one application path' }
    $thumb = if ($options.Contains('tlsCertificateThumbprint')) { ([string]$options.tlsCertificateThumbprint -replace '\s', '').ToUpperInvariant() }else { '' }
    if ($thumb -and $thumb -notmatch '^[A-F0-9]{40}$') { throw 'PVWA tlsCertificateThumbprint must identify a machine-store certificate' }
    if ($options.Contains('createLabCertificate') -and
        $options.createLabCertificate -isnot [bool]) { throw 'PVWA createLabCertificate requires an explicit Boolean' }
    $lab = ($options.Contains('createLabCertificate') -and $options.createLabCertificate)
    if ($lab -and $Settings.SecurityProfile -ne 'Lab') { throw 'PVWA self-signed certificate creation requires explicit Lab policy' }
    if ($thumb -and $lab) { throw 'Select an existing PVWA certificate or explicit Lab creation, not both' }
    if (-not $thumb -and
        -not $lab) { throw 'PVWA HTTPS requires options.tlsCertificateThumbprint in LocalMachine My, or explicit Lab options.createLabCertificate=true' }
    [pscustomobject]@{
        Uri = $uri
        Thumbprint = $thumb
        Lab = $lab
        Application = $uri.AbsolutePath.Trim('/')
        Site = 'Default Web Site'
        Marker = (Join-Path ([string]$Settings.StageRoot) 'pvwa-tls.json')
        FriendlyName = ('PASeasyInstall:' + ([string]$Settings.Id) + ':PVWA:LabTLS')
    }
}
function Assert-PASeasyPvwaCertificate {
    param($Certificate)
    if (-not $Certificate -or
        -not $Certificate.HasPrivateKey -or
        $Certificate.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
        $Certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow.AddMinutes(5)) { throw 'PVWA certificate is missing a private key or is outside its validity period' }
    $serverAuth = @($Certificate.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.1' })
    if (-not $serverAuth.Count) { throw 'PVWA certificate requires Server Authentication EKU' }
    $chain = [Security.Cryptography.X509Certificates.X509Chain]::new()
    try { if (-not $chain.Build($Certificate)) { throw 'PVWA certificate chain is not trusted on the target' } }finally { $chain.Dispose() }
}
function Get-PASeasyPvwaCertificate {
    param($Policy, [switch]$AllowPending)
    if ($Policy.Thumbprint) { return Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $Policy.Thumbprint) -ErrorAction Stop }
    if (Test-Path -LiteralPath $Policy.Marker) {
        $record = Get-Content -LiteralPath $Policy.Marker -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($record.schemaVersion -ne 1 -or
            $record.Uri -cne $Policy.Uri.AbsoluteUri -or
            $record.Thumbprint -notmatch '^[A-F0-9]{40}$') { throw 'PVWA TLS checkpoint is inconsistent; reconcile before continuing' }
        $cert = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $record.Thumbprint) -ErrorAction Stop
        if ($cert.FriendlyName -cne $Policy.FriendlyName -or
            $cert.Subject -ne $cert.Issuer) { throw 'PVWA Lab TLS checkpoint does not identify its owned certificate' }
        return $cert
    }
    $certs = @(Get-ChildItem Cert:\LocalMachine\My -ErrorAction Stop | Where-Object { $_.FriendlyName -ceq $Policy.FriendlyName })
    if ($certs.Count -gt 1) { throw 'Multiple owned PVWA Lab certificates require reconciliation' }
    if ($certs.Count -eq 1) {
        if ($certs[0].Subject -ne $certs[0].Issuer -or
            $certs[0].GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::DnsName, $false) -ine $Policy.Uri.DnsSafeHost) { throw 'Owned PVWA Lab certificate identity differs from the requested host' }
        return $certs[0]
    }
    if ($AllowPending) { return $null }
    throw 'PVWA Lab TLS certificate has not been created'
}
function Test-PASeasyPvwaTlsPreparation {
    param([hashtable]$Settings)
    $policy = Get-PASeasyPvwaTlsPolicy $Settings
    $cert = Get-PASeasyPvwaCertificate $policy -AllowPending:$policy.Lab
    if ($cert) { Assert-PASeasyPvwaCertificate $cert }
    [pscustomobject]@{
        Passed = $true
        CertificatePending = ($null -eq $cert)
        LabSelfSigned = $policy.Lab
        Endpoint = $policy.Uri.AbsoluteUri
    }
}
function Test-PASeasyPvwaTlsTransport {
    param([uri]$Uri, [string]$ExpectedThumbprint)
    # Connect locally but authenticate the configured public name using native chain/name checks.
    $tcp = [Net.Sockets.TcpClient]::new()
    $tls = $null
    try {
        $tcp.Connect('127.0.0.1', $Uri.Port)
        $stream = $tcp.GetStream()
        $stream.ReadTimeout = 10000
        $stream.WriteTimeout = 10000
        $tls = [Net.Security.SslStream]::new($stream, $false)
        $tls.AuthenticateAsClient($Uri.DnsSafeHost, $null, [Security.Authentication.SslProtocols]::Tls12, $true)
        $remote = [Security.Cryptography.X509Certificates.X509Certificate2]::new($tls.RemoteCertificate)
        try { if ($remote.Thumbprint -cne $ExpectedThumbprint) { throw 'PVWA HTTPS served a different certificate' } }finally { $remote.Dispose() }
        [pscustomobject]@{Passed = $true; TLS = 'Tls12'; ChainAndNameValidated = $true; Endpoint = $Uri.AbsoluteUri }
    } finally {
        if ($tls) { $tls.Dispose() }
        $tcp.Dispose()
    }
}
function Get-PASeasyPvwaBindingThumbprint {
    param($Binding)
    if ($Binding.certificateHash -is [byte[]]) { return ([BitConverter]::ToString($Binding.certificateHash)).Replace('-', '') }
    return ([string]$Binding.certificateHash).ToUpperInvariant()
}
function Assert-PASeasyPvwaHttpsBinding {
    param($Policy, $Certificate)
    $bindingInfo = '*:' + $Policy.Uri.Port + ':' + $Policy.Uri.DnsSafeHost
    $bindings = @(Get-WebBinding -Name $Policy.Site -Protocol https -ErrorAction Stop | Where-Object { $_.bindingInformation -ieq $bindingInfo })
    if ($bindings.Count -ne 1 -or
        (Get-PASeasyPvwaBindingThumbprint $bindings[0]) -cne $Certificate.Thumbprint -or
        [string]$bindings[0].certificateStoreName -ine 'My') { throw 'PVWA HTTPS binding does not match the selected certificate' }
    $flags = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location ($Policy.Site + '/' + $Policy.Application) -Filter 'system.webServer/security/access' -Name sslFlags -ErrorAction Stop
    # WebAdministration on supported Server2022 returns a decorated System.String,
    # not a ConfigurationAttribute with a Value property. Reject unexpected shapes.
    if ($flags -isnot [string]) { throw 'PVWA IIS SSL policy returned an unexpected value type' }
    if ($flags -notmatch '(^|,\s*)Ssl($|,)') { throw 'PVWA application does not require HTTPS' }
}
function Invoke-PASeasyPvwaTls {
    param([hashtable]$Settings)
    $policy = Get-PASeasyPvwaTlsPolicy $Settings
    Import-Module WebAdministration -ErrorAction Stop
    $cert = Get-PASeasyPvwaCertificate $policy -AllowPending:$policy.Lab
    if (-not $cert) {
        $cert = New-SelfSignedCertificate -DnsName $policy.Uri.DnsSafeHost -CertStoreLocation Cert:\LocalMachine\My -FriendlyName $policy.FriendlyName -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -NotAfter ([DateTime]::UtcNow.AddYears(1)) -ErrorAction Stop
    }
    if ($policy.Lab) {
        # Explicit, target-local Lab trust only; never imports a private key into Root.
        $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
        $public = [Security.Cryptography.X509Certificates.X509Certificate2]::new($cert.RawData)
        try {
            $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
            $store.Add($public)
        } finally {
            $store.Close()
            $store.Dispose()
            $public.Dispose()
        }
    }
    Assert-PASeasyPvwaCertificate $cert
    $bindingInfo = '*:' + $policy.Uri.Port + ':' + $policy.Uri.DnsSafeHost
    $bindings = @(Get-WebBinding -Name $policy.Site -Protocol https -ErrorAction Stop | Where-Object { $_.bindingInformation -ieq $bindingInfo })
    if ($bindings.Count -gt 1) { throw 'PVWA HTTPS binding is ambiguous' }
    $bindCertificate = $false
    if ($bindings.Count) {
        $current = Get-PASeasyPvwaBindingThumbprint $bindings[0]
        if ($current -and
            ($current -cne $cert.Thumbprint -or
            [string]$bindings[0].certificateStoreName -ine 'My')) { throw 'Refusing to replace a different existing PVWA HTTPS certificate' }
        $bindCertificate = (-not $current)
    } else {
        $bindCertificate = $true
        New-WebBinding -Name $policy.Site -Protocol https -Port $policy.Uri.Port -HostHeader $policy.Uri.DnsSafeHost -SslFlags 1 -ErrorAction Stop |
            Out-Null
        $bindings = @(Get-WebBinding -Name $policy.Site -Protocol https -ErrorAction Stop | Where-Object { $_.bindingInformation -ieq $bindingInfo })
    }
    if ($bindCertificate) { $bindings[0].AddSslCertificate($cert.Thumbprint, 'My') }
    Assert-PASeasyPvwaHttpsBinding $policy $cert
    $transport = Test-PASeasyPvwaTlsTransport -Uri $policy.Uri -ExpectedThumbprint $cert.Thumbprint
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = ([BitConverter]::ToString($sha.ComputeHash($cert.RawData))).Replace('-', '') }finally { $sha.Dispose() }
    $record = @{
        schemaVersion = 1
        Uri = $policy.Uri.AbsoluteUri
        Thumbprint = $cert.Thumbprint
        LabSelfSigned = $policy.Lab
        PublicCertificateSha256 = $fingerprint
        Utc = [DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText($policy.Marker, ($record | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{
        Changed = $true
        Message = $(if ($policy.Lab) { 'SECURITY DEVIATION: explicit Lab PVWA self-signed certificate bound and trusted on this target only' }else { 'PVWA HTTPS bound to the selected trusted certificate' })
        Data = @{
            Hash = $fingerprint
            Metadata = ('PVWA HTTPS certificate ' + $cert.Thumbprint + '; LabSelfSigned=' + $policy.Lab)
        }
        Transport = $transport
    }
}
function Test-PASeasyPvwaTls {
    param([hashtable]$Settings)
    $policy = Get-PASeasyPvwaTlsPolicy $Settings
    $cert = Get-PASeasyPvwaCertificate $policy
    Assert-PASeasyPvwaCertificate $cert
    Import-Module WebAdministration -ErrorAction Stop
    Assert-PASeasyPvwaHttpsBinding $policy $cert
    Test-PASeasyPvwaTlsTransport -Uri $policy.Uri -ExpectedThumbprint $cert.Thumbprint
}
