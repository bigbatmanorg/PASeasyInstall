function Test-PASLabConfiguration {
    <#
    .SYNOPSIS
    Checks a lab configuration: structure, topology rules and, with -CheckMedia, the installer files.
    .DESCRIPTION
    Returns one object with Valid (true or false), Issues (what must be corrected), Warnings and the
    normalized Configuration. Lab security deviations appear as warnings that start with
    "SECURITY DEVIATION". No server is contacted and nothing is changed.

    To check the servers themselves (reachable, WinRM, disk space) use Test-PASPreflight.
    .PARAMETER Path
    Configuration file (JSON).
    .PARAMETER Configuration
    Configuration object, as returned by New-PASLabConfiguration or Import-PASLabConfiguration.
    .PARAMETER CheckMedia
    Also checks that the installer file of every component exists.
    .EXAMPLE
    Test-PASLabConfiguration -Path .\MyLab.json -CheckMedia | Format-List Valid, Issues, Warnings
    .EXAMPLE
    if (-not (Test-PASLabConfiguration -Configuration $cfg).Valid) { 'Not ready yet' }
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Configuration', ValueFromPipeline)]
        $Configuration,

        [switch]$CheckMedia
    )

    process {
        $source = Resolve-PASConfigurationInput -Path $Path -Configuration $Configuration
        return (Test-PASConfiguration @source -CheckMedia:$CheckMedia)
    }
}
