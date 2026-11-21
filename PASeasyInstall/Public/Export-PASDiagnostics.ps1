function Export-PASDiagnostics {
    <#
    .SYNOPSIS
    Writes a sanitized ZIP of one run (configuration, plan, status and event journals) for support or documentation.
    .DESCRIPTION
    Credential files, lock files and the generated payload folder (scripts and per-component
    inventories) are never included. Every file is scanned for private keys, credential ciphers and
    password fields; a file with a hit is left out and listed in the result.

    Only local files of the run are read; no server is contacted. Look through the ZIP before you
    share it: it contains the server names and addresses of your lab.
    .PARAMETER RunId
    Run id (32 hexadecimal characters).
    .PARAMETER Path
    ZIP file to create. Default: .\PASeasyInstall-run-<RunId>.zip
    .PARAMETER Force
    Replaces an existing file.
    .EXAMPLE
    Export-PASDiagnostics -RunId 688d8e04f1874d41a75cda4441c00553
    .EXAMPLE
    Get-PASRun -Last 1 | Export-PASDiagnostics -Path C:\Temp\lab-run.zip -Force
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[0-9a-fA-F]{32}$')]
        [string]$RunId,

        [string]$Path = '',

        [switch]$Force
    )

    process {
        $id = $RunId.ToLowerInvariant()
        if (-not (Get-PASRunRecord -RunId $id)) {
            throw "Run $id was not found under $(Get-PASDataRoot). Get-PASRun lists the runs of this controller."
        }
        if ($Path) {
            # Relative paths are relative to the current PowerShell location.
            $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        }
        return (Export-PASDeploymentData -RunId $id -Path $Path -Force:$Force)
    }
}
