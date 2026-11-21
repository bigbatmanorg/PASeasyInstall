function Get-PASLabPlan {
    <#
    .SYNOPSIS
    Shows what a configuration would install: one item per component with its server, installer and order.
    .DESCRIPTION
    A dry run. Returns the plan with Name, Items, DomainJoins and Warnings. Each item has Id, Name, Type,
    Host, Address, Os, Media and DependsOn; the items are listed in installation order. No server is
    contacted and nothing is changed.

    With -ResolveMedia the exact installer files are resolved and hashed too (plan properties Media and
    MediaDigest). That reads every installer once and can take a few minutes.
    .PARAMETER Path
    Configuration file (JSON).
    .PARAMETER Configuration
    Configuration object, as returned by New-PASLabConfiguration or Import-PASLabConfiguration.
    .PARAMETER ResolveMedia
    Also resolves and hashes the installer files that would be used.
    .EXAMPLE
    (Get-PASLabPlan -Path .\MyLab.json).Items | Format-Table Id, Type, Address, Media, DependsOn
    .EXAMPLE
    Get-PASLabPlan -Configuration $cfg -ResolveMedia | Select-Object -ExpandProperty Media
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Configuration', ValueFromPipeline)]
        $Configuration,

        [switch]$ResolveMedia
    )

    process {
        $ready = Get-PASValidatedConfiguration -Path $Path -Configuration $Configuration
        $plan = Get-PASDeploymentPlan -Configuration $ready -ResolveMedia:$ResolveMedia
        return (Add-PASPlanDetail -Plan $plan -Configuration $ready)
    }
}
