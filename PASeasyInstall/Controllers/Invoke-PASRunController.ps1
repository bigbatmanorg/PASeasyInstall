[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$DataRoot,
      [Parameter(Mandatory)][string]$Envelope,[switch]$Resume,[switch]$RetryFailedPreflight)
$ErrorActionPreference='Stop'
try {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall.Core.psd1') -Force
    & (Get-Module PASeasyInstall.Core) {
        param($id,$root,$credentialEnvelope,$resumeRun,$retryPreflight)
        Invoke-PASeasyInternalController -RunId $id -DataRoot $root -Envelope $credentialEnvelope -Resume:$resumeRun -RetryFailedPreflight:$retryPreflight
    } $RunId $DataRoot $Envelope ([bool]$Resume) ([bool]$RetryFailedPreflight)
} catch {
    # Only the controller holding its lifetime lease may publish an outcome.
    # A losing concurrent launcher must not write over that active owner.
    Write-Error 'Deployment controller stopped. Inspect Get-PASeasyRun and Get-PASeasyLog for its recorded outcome.' -ErrorAction Continue
    exit 1
} finally {
    if(Test-Path -LiteralPath $Envelope){Remove-Item -LiteralPath $Envelope -Force -ErrorAction SilentlyContinue}
}
