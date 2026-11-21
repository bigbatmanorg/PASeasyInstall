# Public certificate trust only. Target file and SHA256 are frozen by the controller.
function Get-PASeasyCpmTrustCertificate {
    param([hashtable]$Settings)
    $path = [string]$Settings.PVWATrustCertificateTarget
    if (-not $path) { return $null }
    $expected = [string]$Settings.PVWATrustCertificateSHA256
    if ($expected -notmatch '^[A-Fa-f0-9]{64}$' -or
        -not(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'CPM public trust certificate requires its frozen SHA256 and staged file' }
    if ((Get-Item -LiteralPath $path -Force).Length -gt 1MB) { throw 'CPM public trust certificate exceeds its size bound' }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $expected) { throw 'CPM public trust certificate differs from its frozen SHA256' }
    $bytes = [IO.File]::ReadAllBytes($path)
    # One public certificate (DER), or a PKCS#7 bundle of public certificates: one per PVWA of the deployment.
    $contentType = [Security.Cryptography.X509Certificates.X509Certificate2]::GetCertContentType($bytes)
    $certificates = @()
    if ($contentType -eq [Security.Cryptography.X509Certificates.X509ContentType]::Cert) {
        $certificates = @([Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes))
    } elseif ($contentType -eq [Security.Cryptography.X509Certificates.X509ContentType]::Pkcs7) {
        $collection = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
        $collection.Import($bytes)
        $certificates = @($collection)
    } else {
        throw 'CPM trust input must be a public certificate, never PFX or a serialized key container'
    }
    try {
        if (-not $certificates.Count) { throw 'CPM trust input contains no certificate' }
        $labLeaf = $false
        foreach ($cert in $certificates) {
            if ($cert.HasPrivateKey -or
                $cert.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or
                $cert.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow.AddMinutes(5)) { throw 'CPM trust certificate is private or outside its validity period' }
            $ca = @($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' })
            $usage = @($cert.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.15' })
            $isCA = ($ca.Count -eq 1 -and
                $ca[0].CertificateAuthority -and
                $usage.Count -eq 1 -and
                ($usage[0].KeyUsages -band [Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyCertSign))
            if (-not $isCA -and
                -not ($Settings.SecurityProfile -eq 'Lab' -and
                    $Settings.AllowPinnedLeafTrust -is [bool] -and
                    $Settings.AllowPinnedLeafTrust)) { throw 'CPM leaf trust requires an explicit Lab AllowPinnedLeafTrust override' }
            if ($Settings.SecurityProfile -ne 'Lab' -and
                (-not $isCA -or
                $cert.Subject -cne $cert.Issuer)) { throw 'Secure CPM trust requires a self-signed CA certificate with Certificate Signing key usage' }
            if ($Settings.SecurityProfile -eq 'Lab' -and -not $isCA) { $labLeaf = $true }
        }
        [pscustomobject]@{
            Certificate = $certificates[0]
            Certificates = $certificates
            SHA256 = $expected.ToUpperInvariant()
            LabLeaf = $labLeaf
        }
    } catch {
        foreach ($cert in $certificates) { $cert.Dispose() }
        throw
    }
}
function Test-PASeasyCpmTls {
    param([hashtable]$Settings)
    $item = Get-PASeasyCpmTrustCertificate $Settings
    if (-not $item) {
        return [pscustomobject]@{
            Passed = $true
            Detail = 'No additional public root supplied; existing Windows trust remains in force'
            LabDeviation = $false
        }
    }
    try {
        foreach ($cert in $item.Certificates) {
            $present = Get-Item -LiteralPath ('Cert:\LocalMachine\Root\' + $cert.Thumbprint) -ErrorAction SilentlyContinue
            if (-not $present -or
                [Convert]::ToBase64String($present.RawData) -cne [Convert]::ToBase64String($cert.RawData)) { throw 'CPM pinned public trust certificate is not present in the machine Root store' }
        }
        [pscustomobject]@{
            Passed = $true
            Detail = 'Frozen public certificate is present in target machine trust'
            SHA256 = $item.SHA256
            Thumbprint = $item.Certificate.Thumbprint
            LabDeviation = $item.LabLeaf
        }
    } finally {
        foreach ($cert in $item.Certificates) { $cert.Dispose() }
    }
}
function Add-PASeasyCpmTrustCertificate {
    param([Security.Cryptography.X509Certificates.X509Certificate2]$Certificate)
    $store = [Security.Cryptography.X509Certificates.X509Store]::new('Root', 'LocalMachine')
    try {
        $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($Certificate)
    } finally {
        $store.Close()
        $store.Dispose()
    }
}
function Invoke-PASeasyCpmTls {
    param([hashtable]$Settings)
    $item = Get-PASeasyCpmTrustCertificate $Settings
    if (-not $item) {
        return [pscustomobject]@{
            Changed = $false
            Message = 'CPM uses existing Windows trust; HTTPS certificate validation remains enabled'
        }
    }
    try {
        foreach ($cert in $item.Certificates) { Add-PASeasyCpmTrustCertificate -Certificate $cert }
        $evidence = Test-PASeasyCpmTls $Settings
        [pscustomobject]@{
            Changed = $true
            Message = $(if ($item.LabLeaf) { 'SECURITY DEVIATION: explicit Lab SHA256-pinned public leaf trusted on CPM target' }else { 'SHA256-pinned public CA trusted on CPM target' })
            Data = @{
                Hash = $item.SHA256
                Metadata = ($evidence.Detail + '; LabLeaf=' + $item.LabLeaf)
            }
        }
    } finally {
        foreach ($cert in $item.Certificates) { $cert.Dispose() }
    }
}
