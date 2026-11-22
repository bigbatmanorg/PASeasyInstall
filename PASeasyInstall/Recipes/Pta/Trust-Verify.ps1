# Read-only check of Trust-Pta.ps1: the certificate PTA presents now is one of the trusted roots of this server.
param([hashtable]$Settings)
$ErrorActionPreference = 'Stop'
$record = Join-Path ([string]$Settings.StageRoot) ('pta-trust-' + [string]$Settings.PtaName + '.json')
$passed = $false
$detail = 'no trust record on this PVWA server'
if (Test-Path -LiteralPath $record -PathType Leaf) {
    $data = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
    $passed = [bool](Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq [string]$data.thumbprint })
    $detail = "certificate $($data.subject) in the trusted roots: $passed"
}
return [pscustomobject]@{ Passed = $passed; Message = "PVWA trust of PTA: $detail"; Evidence = @("Trusted=$passed") }
