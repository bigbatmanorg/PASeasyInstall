# Runs on a PVWA server of a lab: makes PVWA able to reach PTA over HTTPS.
# PTA has a certificate it made itself. Lab only: the certificate PTA presents is put into the trusted roots of
# this server (trusted on first use), and the PTA name gets a hosts entry when it does not resolve.
[CmdletBinding()]
param([hashtable]$Settings)
$ErrorActionPreference = 'Stop'
if ([string]$Settings.SecurityProfile -ne 'Lab') {
    throw 'Trusting the certificate PTA presents is a Lab deviation. Secure profile: install a PTA certificate of your certificate authority instead.'
}
$address = [string]$Settings.PtaAddress
$name = [string]$Settings.PtaName
$port = [int]$Settings.PtaPort
$client = New-Object Net.Sockets.TcpClient
$ssl = $null
try {
    $client.Connect($address, $port)
    $accept = [Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $e) $true }
    $ssl = New-Object Net.Security.SslStream($client.GetStream(), $false, $accept)
    $ssl.AuthenticateAsClient($name, $null, [Security.Authentication.SslProtocols]::Tls12, $false)
    $certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2($ssl.RemoteCertificate)
} finally {
    if ($ssl) {
        $ssl.Dispose()
    }
    $client.Dispose()
}
$store = New-Object Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
try {
    $known = @($store.Certificates | Where-Object { $_.Thumbprint -eq $certificate.Thumbprint }).Count
    if (-not $known) {
        $store.Add($certificate)
    }
} finally {
    $store.Close()
}
$hostsChanged = $false
$resolves = $false
try {
    $resolves = (@([Net.Dns]::GetHostAddresses($name)).Count -gt 0)
} catch {
    $resolves = $false
}
if (-not $resolves) {
    Add-Content -LiteralPath (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') -Value ($address + ' ' + $name)
    $hostsChanged = $true
}
@{ thumbprint = $certificate.Thumbprint; subject = $certificate.Subject; address = $address } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path ([string]$Settings.StageRoot) ('pta-trust-' + $name + '.json')) -Encoding UTF8
return [pscustomobject]@{
    Changed = (-not $known -or $hostsChanged)
    Message = "SECURITY DEVIATION (Lab): this PVWA server trusts the certificate PTA presented ($($certificate.Subject), $($certificate.Thumbprint))"
}
