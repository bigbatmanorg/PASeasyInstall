function Get-PASRunLog {
    <#
    .SYNOPSIS
    Reads the controller journal of a run, or the tail of a CyberArk log file on one of the lab servers.
    .DESCRIPTION
    Two uses:

    -RunId: the raw records of the run controller's journal (events.jsonl in the run folder), oldest
    first. Local files only. For the merged, readable progress of a run use Get-PASRunEvent.

    -Path and -Component: the last lines of a product log on the server of that component, read over
    WinRM (Windows, needs -Credential) or SSH (Linux, with the key of the configuration). Only the log
    files of the module's catalog can be read: Data\LogSources.json in the module folder lists them per
    component type with their names. Read-only; nothing is changed on the server.
    .PARAMETER RunId
    Run id (32 hexadecimal characters).
    .PARAMETER Path
    Configuration file (JSON) that describes the lab.
    .PARAMETER Component
    Id of the component in the configuration, e.g. vault, pvwa01.
    .PARAMETER LogName
    Name of the log in the catalog, e.g. italog for a Vault. Default: the first log of the component type.
    .PARAMETER Credential
    Windows account for the server of the component. Required for Windows servers.
    .PARAMETER Tail
    How many of the last records or lines to return (1 to 10000). Default 200.
    .EXAMPLE
    Get-PASRunLog -RunId 688d8e04f1874d41a75cda4441c00553 -Tail 20 | Format-Table timestampUtc, event, component, message
    .EXAMPLE
    Get-PASRunLog -Path .\MyLab.json -Component vault -LogName italog -Credential (Get-Credential Administrator) -Tail 100

    Shows the last 100 lines of the Vault's ITALog.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Run')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Run', Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[0-9a-fA-F]{32}$')]
        [string]$RunId,

        [Parameter(Mandatory, ParameterSetName = 'Server')]
        [Alias('Config')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Server')]
        [string]$Component,

        [Parameter(ParameterSetName = 'Server')]
        [string]$LogName = 'default',

        [Parameter(ParameterSetName = 'Server')]
        [pscredential]$Credential,

        [ValidateRange(1, 10000)]
        [int]$Tail = 200
    )

    process {
        if ($PSCmdlet.ParameterSetName -eq 'Run') {
            $id = $RunId.ToLowerInvariant()
            if (-not (Get-PASRunRecord -RunId $id)) {
                throw "Run $id was not found under $(Get-PASDataRoot). Get-PASRun lists the runs of this controller."
            }
            return @(Get-PASDeploymentLog -RunId $id -Tail $Tail)
        }

        $source = Resolve-PASConfigurationInput -Path $Path
        $log = @{
            Config    = $source.Config
            Component = $Component
            Name      = $LogName
            Tail      = $Tail
        }
        if ($Credential) {
            # WinRM to a workgroup server needs the '.\Administrator' form: the same rule as for a run.
            $configuration = Read-PASConfiguration -Path $source.Config
            $normalized = ConvertTo-PASControllerCredentialMap $configuration @{ $Component = $Credential }
            $log['Credential'] = $normalized[$Component]
        }
        return @(Get-PASDeploymentLog @log)
    }
}
