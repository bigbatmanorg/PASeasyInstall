# Runs on a PVWA server of a lab: makes PVWA able to reach PTA over HTTPS.
# PTA has a certificate it made itself. Lab only: the certificate PTA presents is put into the trusted roots of
# this server (trusted on first use), and the names PVWA uses for PTA get a hosts entry when they do not lead to it.
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
# PVWA reaches PTA under the name PTA registered in the Vault: its own host name, the one in its certificate
# (labpta01), not the name of the configuration (pta01). Without DNS for that name, PVWA cannot reach PTA and
# System Health shows PTA as not connected. So every name of the certificate must lead to this address (the
# configured name only when the certificate names no host).
$names = @()
$cn = [regex]::Match([string]$certificate.Subject, '(?:^|,\s*)CN=([^,]+)').Groups[1].Value.Trim()
if ($cn) { $names += $cn }
$san = $certificate.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.17' }
if ($san) {
    foreach ($line in ($san.Format($true) -split "`r?`n")) {
        if ($line -match '^\s*DNS Name=(.+)$') { $names += $Matches[1].Trim() }
    }
}
$names = @($names | Where-Object { $_ -match '^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$' } | Select-Object -Unique)
if (-not $names.Count) { $names = @($name) }
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsChanged = $false
foreach ($entry in $names) {
    $resolved = @()
    try {
        $resolved = @([Net.Dns]::GetHostAddresses($entry) | ForEach-Object { $_.IPAddressToString })
    } catch {
        $resolved = @()
    }
    if ($resolved -notcontains $address) {
        Add-Content -LiteralPath $hostsPath -Value ($address + ' ' + $entry + ' # PASeasyInstall: PTA')
        $hostsChanged = $true
    }
}
@{ thumbprint = $certificate.Thumbprint; subject = $certificate.Subject; address = $address; names = $names } |
    ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path ([string]$Settings.StageRoot) ('pta-trust-' + $name + '.json')) -Encoding UTF8
return [pscustomobject]@{
    Changed = (-not $known -or $hostsChanged)
    Message = "SECURITY DEVIATION (Lab): this PVWA server trusts the certificate PTA presented ($($certificate.Subject), $($certificate.Thumbprint)) and reaches PTA as $($names -join ', ')"
}
