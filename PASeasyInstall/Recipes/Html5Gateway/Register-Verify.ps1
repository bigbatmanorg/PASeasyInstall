# Read-only check of Register-Gateway.ps1: the record it wrote after it read the stored configuration back.
param([string]$Stage, [hashtable]$Settings)
$ErrorActionPreference = 'Stop'
$record = Join-Path ([string]$Settings.WorkRoot) ('registered-' + [string]$Settings.GatewayId + '.json')
$passed = $false
$detail = 'no registration record on this PVWA server'
if (Test-Path -LiteralPath $record -PathType Leaf) {
    $data = Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
    $passed = ([string]$data.gatewayId -eq [string]$Settings.GatewayId -and
        [string]$data.address -eq [string]$Settings.GatewayAddress -and
        [string]$data.port -eq [string][int]$Settings.GatewayPort -and
        [int]$data.psmServers -gt 0)
    $detail = "gateway $($data.gatewayId) at $($data.address):$($data.port) for $($data.psmServers) PSM server(s)"
}
return [pscustomobject]@{ Passed = $passed; Message = "PVWA configuration: $detail"; Evidence = @("Registered=$passed") }
