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

    The window is drawn with WPF, which is part of Windows: nothing else has to be installed.

    The window opens in its own process and the command returns at once: the prompt stays usable, and
    closing the prompt does not close the window. When the window cannot start, the command says why.

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

    # The window runs in its own Windows PowerShell process, started with a single-threaded apartment as WPF
    # needs it. This prompt stays free, and the window does not depend on what this session has loaded.
    $logFolder = Get-PASDataRoot
    if (-not (Test-Path -LiteralPath $logFolder)) {
        New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    }
    $outLog = Join-Path $logFolder 'desktop.out.log'
    $errorLog = Join-Path $logFolder 'desktop.err.log'
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy Bypass', '-File', ('"' + (Join-Path $desktop 'App.ps1') + '"'),
        '-Backend', $Backend, '-StartDirectory', ('"' + (Get-Location).ProviderPath.TrimEnd('\') + '"'))
    if ($Config) {
        $arguments += @('-Config', ('"' + $Config + '"'))
    }
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errorLog

    # A window that cannot start ends within a few seconds: say why instead of showing nothing.
    if ($process.WaitForExit(5000) -and $process.ExitCode -ne 0) {
        $reason = ''
        if (Test-Path -LiteralPath $errorLog) {
            $reason = (@(Get-Content -LiteralPath $errorLog -ErrorAction SilentlyContinue | Where-Object { $_ }) | Select-Object -First 6) -join ' '
        }
        throw "The desktop window could not start (exit code $($process.ExitCode)). $reason Details: $errorLog"
    }
}
