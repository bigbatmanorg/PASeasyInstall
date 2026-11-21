function Start-PASeasyInstall {
    <#
    .SYNOPSIS
    Opens the PASeasyInstall desktop: a window that builds a CyberArk PAM lab in four steps.
    .DESCRIPTION
    The steps are: media folder, the lab to build, servers and password, review and install. A start
    page lists the installations of this computer; each has a page with live progress, retry and a lab
    check. Nothing is sent to any server before you press Install on the last step. "Advanced" shows
    the settings most labs never need.

    The window only calls the other commands of this module (New-PASLabConfiguration,
    Test-PASLabConfiguration, Get-PASLabPlan, Install-PASLab, Get-PASRun, ...), so everything it does
    can also be done from the prompt.

    The window is drawn by the NativeHTMLKit module. The commands do not need it; only this one does.
    When it is not installed you are asked whether to install it from the PowerShell Gallery (for the
    current user). The portable ZIP carries its own copy.

    Needs Windows PowerShell 5.1. PASeasyInstall builds labs. Production use is at your own risk.
    .PARAMETER Config
    Optional lab file (JSON, saved from the window or by Export-PASLabConfiguration). Its name, Vault
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
    $desktop = Join-Path $script:PASRoot 'Desktop'

    # The window engine: installed, or in the folder next to this module (portable ZIP).
    $bundled = Join-Path (Split-Path -Parent $script:PASRoot) 'NativeHTMLKit'
    $available = [bool](Get-Module -ListAvailable -Name NativeHTMLKit)
    if (-not $available -and -not (Test-Path -LiteralPath $bundled -PathType Container)) {
        $question = 'The desktop window needs the NativeHTMLKit module (the window engine). Install it now from the PowerShell Gallery for the current user?'
        if (-not $PSCmdlet.ShouldContinue($question, 'NativeHTMLKit is not installed')) {
            throw 'The desktop needs the NativeHTMLKit module. Install it with: Install-Module NativeHTMLKit -Scope CurrentUser. The other PASeasyInstall commands work without it.'
        }
        Install-Module -Name NativeHTMLKit -Scope CurrentUser -Force -ErrorAction Stop
    }

    & (Join-Path $desktop 'App.ps1') -Config $Config -Backend $Backend
}
