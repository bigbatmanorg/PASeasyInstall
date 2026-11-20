function Export-PASLabConfiguration {
    <#
    .SYNOPSIS
    Saves a lab configuration as a JSON file. The file never contains a password.
    .DESCRIPTION
    Validates the configuration first; a configuration with issues is not saved. An existing file is
    only replaced with -Force. The file is written completely or not at all. Returns the full path.

    Read the file again with Import-PASLabConfiguration, or pass it to Install-PASLab -Path.
    .PARAMETER Configuration
    Configuration object, as returned by New-PASLabConfiguration.
    .PARAMETER Path
    File to write, e.g. .\MyLab.json. The folder is created when it does not exist.
    .PARAMETER Force
    Replaces an existing file.
    .EXAMPLE
    Export-PASLabConfiguration -Configuration $cfg -Path .\MyLab.json
    .EXAMPLE
    $cfg | Export-PASLabConfiguration -Path D:\Labs\MyLab.json -Force
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $Configuration,

        [Parameter(Mandatory, Position = 0)]
        [string]$Path,

        [switch]$Force
    )

    process {
        $ready = Get-PASValidatedConfiguration -Configuration $Configuration
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        if ((Test-Path -LiteralPath $full) -and -not $Force) {
            throw "The file already exists: $full. Choose another name, or use -Force to replace it."
        }
        if ($PSCmdlet.ShouldProcess($full, 'Save the lab configuration')) {
            Write-PASJsonAtomic -Path $full -Data $ready
            return $full
        }
    }
}
