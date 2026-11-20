# The desktop wizard. Importing this module opens no window and contacts no server.
Set-StrictMode -Version 2.0

function Start-PASeasyInstall {
    <#
    .SYNOPSIS
    Opens the PASeasyInstall desktop: a six-step wizard that builds a CyberArk PAM lab.
    .DESCRIPTION
    The steps are: project and media, what to install, servers, credentials, review plan, and install with
    live progress. Nothing is sent to any server before you press Install on the last step.
    The wizard only calls the public commands of the PASeasyInstall module (New-PASLabConfiguration,
    Test-PASLabConfiguration, Get-PASLabPlan, Install-PASLab, Get-PASRun, ...), so everything it does can
    also be done from the prompt. Needs Windows PowerShell 5.1 and NativeHTMLKit.UI.
    PASeasyInstall builds labs. Production use is at your own risk.
    .PARAMETER Config
    Optional project file (JSON, written by the wizard or by Export-PASLabConfiguration). Its name, Vault
    option, addresses and component servers are filled in; media and passwords are entered again.
    .PARAMETER Backend
    Live (default) runs real installations. Mock simulates the installation and never contacts a server,
    which is useful for demos and training.
    .EXAMPLE
    Start-PASeasyInstall
    .EXAMPLE
    Start-PASeasyInstall -Config .\PASeasyInstall-Lab01.json
    .EXAMPLE
    Start-PASeasyInstall -Backend Mock
    #>
    [CmdletBinding()]
    param(
        [string]$Config = '',
        [ValidateSet('Live', 'Mock')][string]$Backend = 'Live'
    )
    if ($Config) {
        $Config = (Resolve-Path -LiteralPath $Config).ProviderPath
    }
    & (Join-Path $PSScriptRoot 'App.ps1') -Config $Config -Backend $Backend
}

Export-ModuleMember -Function Start-PASeasyInstall
