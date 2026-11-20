# Standalone presentation module. Importing this does not create a window or execute deployment.
Set-StrictMode -Version 2.0
function Start-PASeasyUI {
    <#
    .SYNOPSIS
    Opens the PASeasyInstall desktop.
    .PARAMETER Backend
    Orchestrator (default): the real PASeasyInstall.Orchestrator, from -ModulesRoot or the Modules
    folder this module is installed in.
    Mock: dummy backend for UI work, contacts no servers.
    #>
    [CmdletBinding()]param([string]$Config='',[switch]$Advanced,
        [ValidateSet('Mock','Orchestrator')][string]$Backend='Orchestrator',[string]$ModulesRoot='',
    [ValidateSet('v1','v2')][string]$Theme='v2')
    if(-not (Get-Module -ListAvailable -Name NativeHTMLKit.UI)){
        throw 'NativeHTMLKit.UI is required. Install-Module NativeHTMLKit.UI -Scope CurrentUser'
    }
    $entry=Join-Path $PSScriptRoot 'App.ps1'
    & $entry -Config $Config -Advanced:$Advanced -Backend $Backend -ModulesRoot $ModulesRoot -Theme $Theme
}
Export-ModuleMember -Function Start-PASeasyUI
