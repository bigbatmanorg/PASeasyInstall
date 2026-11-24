# Read-only check of Trust-Pta.ps1: the certificate PTA presents is one of the trusted roots of this server, and
# PVWA reaches PTA over HTTPS under the name PTA registered in the Vault (the name in its certificate), the way
# PVWA System Health does. A missing hosts entry for that name fails here, not later in the lab check.
param([hashtable]$Settings)
$ErrorActionPreference = 'Stop'
$record = Join-Path ([string]$Settings.StageRoot) ('pta-trust-' + [string]$Settings.PtaName + '.json')
if (-not (Test-Path -LiteralPath $record -PathType Leaf)) {
    return [pscustomobject]@{ Passed = $false; Message = 'PVWA trust of PTA: no trust record on this PVWA server'; Evidence = @() }
}
$data = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
$trusted = [bool](Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq [string]$data.thumbprint })
$cn = [regex]::Match([string]$data.subject, '(?:^|,\s*)CN=([^,]+)').Groups[1].Value.Trim()
$names = @(@($data.names) | Where-Object { $_ })
if (-not $names.Count -and $cn) { $names = @($cn) }
$port = [int]$Settings.PtaPort
$reached = @()
$failed = @()
$previous = [Net.ServicePointManager]::SecurityProtocol
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try {
    foreach ($name in $names) {
        $uri = 'https://' + $name + $(if ($port -and $port -ne 443) { ':' + $port }else { '' }) + '/'
        $request = [Net.HttpWebRequest]::Create($uri)
        $request.Timeout = 20000
        $request.AllowAutoRedirect = $false
        try {
            $response = $request.GetResponse()
            $response.Close()
            $reached += $name
        } catch [Net.WebException] {
            # An HTTP answer of any status means name, connection and certificate are all good.
            if ($_.Exception.Response) {
                $_.Exception.Response.Close()
                $reached += $name
            } else {
                $failed += ($name + ': ' + $_.Exception.Message)
            }
        }
    }
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $previous
}
$passed = ($trusted -and $names.Count -gt 0 -and -not $failed.Count)
$detail = "certificate $($data.subject) in the trusted roots: $trusted; HTTPS to PTA as $($reached -join ', ')"
if ($failed.Count) { $detail += '; not reachable: ' + ($failed -join '; ') }
return [pscustomobject]@{ Passed = $passed; Message = "PVWA trust of PTA: $detail"; Evidence = @("Trusted=$trusted", ('Reached=' + ($reached -join ','))) }
