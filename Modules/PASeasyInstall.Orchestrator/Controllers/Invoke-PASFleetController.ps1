# Detached deployment controller for a composed (multi-unit) deployment. Started by
# Start-PASEnvironment; reads and deletes its DPAPI credential envelope, then runs the units.
[CmdletBinding()]param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$FleetId,
    [Parameter(Mandatory)][string]$DataRoot,[Parameter(Mandatory)][string]$Envelope)
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall.Orchestrator.psd1') -Force
& (Get-Module PASeasyInstall.Orchestrator) { param($f,$d,$e) Invoke-PASFleetController -FleetId $f -DataRoot $d -Envelope $e } $FleetId $DataRoot $Envelope
