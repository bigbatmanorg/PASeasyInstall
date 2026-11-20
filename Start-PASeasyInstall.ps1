<#
.SYNOPSIS
Opens the PASeasyInstall desktop.
.DESCRIPTION
Opens the six-step installer desktop (NativeHTMLKit.UI, Windows PowerShell 5.1 or PowerShell 7).
By default it drives the real installer (the Orchestrator in this folder's Modules). Nothing is sent
to any server until Install on step 6. -Backend Mock runs the same window against a dummy backend that
simulates plans and installations and never contacts a server (UI development, demos).
.EXAMPLE
.\Start-PASInstall.ps1
.EXAMPLE
.\Start-PASInstall.ps1 -Advanced
.EXAMPLE
.\Start-PASInstall.ps1 -Backend Mock
#>
[CmdletBinding()]param([string]$Config='',[switch]$Advanced,
    [ValidateSet('Mock','Orchestrator')][string]$Backend='Orchestrator',[string]$ModulesRoot='',
    [ValidateSet('v1','v2')][string]$Theme='v2')
$ErrorActionPreference='Stop'
$moduleFile=Join-Path $PSScriptRoot 'Modules/PASeasyInstall.UI/PASeasyInstall.UI.psd1'
if(-not(Test-Path -LiteralPath $moduleFile -PathType Leaf)){throw "PASeasyInstall UI module not found: $moduleFile"}
if($ModulesRoot){$ModulesRoot=[IO.Path]::GetFullPath($ModulesRoot)}
Import-Module $moduleFile -Force -ErrorAction Stop
Start-PASeasyUI -Config $Config -Advanced:$Advanced -Backend $Backend -ModulesRoot $ModulesRoot -Theme $Theme
