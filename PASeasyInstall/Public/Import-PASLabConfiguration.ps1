function Import-PASLabConfiguration {
    <#
    .SYNOPSIS
    Reads a lab configuration from a JSON file and returns it as an ordered hashtable.
    .DESCRIPTION
    The result can be changed in memory (for example $cfg.hosts.pvwa01.address = '192.0.2.31') and then
    passed to Test-PASLabConfiguration, Get-PASLabPlan, Install-PASLab or Export-PASLabConfiguration.
    The file is only read and parsed; use Test-PASLabConfiguration to validate it.
    .PARAMETER Path
    Configuration file (JSON), as written by Export-PASLabConfiguration or the desktop wizard.
    .EXAMPLE
    $cfg = Import-PASLabConfiguration -Path .\MyLab.json
    .EXAMPLE
    $cfg = Import-PASLabConfiguration .\MyLab.json
    $cfg.name = 'MyLab2'
    Export-PASLabConfiguration -Configuration $cfg -Path .\MyLab2.json

    Copies a configuration under a new environment name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path
    )

    process {
        $source = Resolve-PASConfigurationInput -Path $Path
        try {
            $data = Get-Content -LiteralPath $source.Config -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "$($source.Config) is not a valid JSON file: $($_.Exception.Message)"
        }
        $configuration = ConvertTo-PASOrderedHashtable $data
        if ($configuration -isnot [System.Collections.IDictionary]) {
            throw "$($source.Config) does not contain a lab configuration (a JSON object was expected)."
        }
        return $configuration
    }
}
