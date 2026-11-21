<#
.SYNOPSIS
Opens the PASeasyInstall desktop from a source checkout or the portable ZIP.
.DESCRIPTION
Imports the PASeasyInstall module from this folder and runs Start-PASeasyInstall: four steps
that build a CyberArk PAM lab. Windows PowerShell 5.1 only; needs the NativeHTMLKit module.
Nothing is sent to any server until Install on the last step. -Backend Mock runs the same window against a
simulated installation that never contacts a server (demos, training, UI work).
.EXAMPLE
.\Start-PASeasyInstall.ps1
.EXAMPLE
.\Start-PASeasyInstall.ps1 -Config .\PASeasyInstall-Lab01.json
.EXAMPLE
.\Start-PASeasyInstall.ps1 -Backend Mock
#>
[CmdletBinding()]
param(
    [string]$Config = '',
    [ValidateSet('Live', 'Mock')][string]$Backend = 'Live'
)
$ErrorActionPreference = 'Stop'
$moduleFile = Join-Path (Join-Path $PSScriptRoot 'PASeasyInstall') 'PASeasyInstall.psd1'
if (-not (Test-Path -LiteralPath $moduleFile -PathType Leaf)) {
    throw "PASeasyInstall module not found: $moduleFile"
}
Import-Module $moduleFile -Force -ErrorAction Stop
Start-PASeasyInstall -Config $Config -Backend $Backend
