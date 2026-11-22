function Get-PASStageCatalog {
    <#
    .SYNOPSIS
    Lists the installation stages of a component type, in the order they run.
    .DESCRIPTION
    Returns one object per stage with Component, Stage and Order. The stage names are the step ids you
    see as Stage in Get-PASRunEvent and that Resume-PASRun -RetryStep accepts.

    The list is read from what the installer really runs: the Vault and DR workflow files of the
    module, and the step list the workflow generator uses for PVWA, CPM, PSM, PSMP and AD.
    Not listed, because they depend on the run: the extra passes and restarts of a PSM stage
    (<stage>-pass2, <stage>-reboot), the upload of a certificate pinned by CPM (pvwa-trust-certificate)
    and the steps the controller performs itself (ssh-bootstrap, media-select).
    .PARAMETER Component
    Vault, DR, PVWA, CPM, PSM, PSMP or AD. Default: all of them.
    .EXAMPLE
    Get-PASStageCatalog -Component Vault | Format-Table Order, Stage
    .EXAMPLE
    'PVWA', 'CPM' | Get-PASStageCatalog | Format-Table Component, Order, Stage
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [ValidateSet('Vault', 'DR', 'PVWA', 'CPM', 'PSM', 'PSMP', 'HTML5GW', 'PTA', 'AD')]
        [string[]]$Component = @('Vault', 'DR', 'PVWA', 'CPM', 'PSM', 'PSMP', 'HTML5GW', 'PTA', 'AD')
    )

    process {
        foreach ($type in $Component) {
            $stages = @()
            if ($type -in @('Vault', 'DR')) {
                # Step ids of the workflow files a run executes for a Primary Vault and for a DR Vault.
                $files = @('VaultPrimaryOnly.psd1')
                if ($type -eq 'DR') {
                    $files = @('VaultDR-Phase1.psd1', 'VaultDR-Phase2.psd1')
                }
                foreach ($file in $files) {
                    $workflow = Import-PowerShellDataFile -Path (Get-PASRecipePath ('Recipes/Vault/Workflows/' + $file))
                    $stages += @($workflow.Steps | ForEach-Object { [string]$_.Id })
                }
            } elseif ($type -eq 'AD') {
                $stages = @(Get-PASComponentStageNames 'AD')
            } else {
                # Steps before the recipe stages: the management endpoint (Windows only), the upload
                # of the installer and the read-only preflight. Then one step per recipe stage.
                if ($type -notin @('PSMP', 'HTML5GW', 'PTA')) {
                    $stages += 'management'
                }
                $stages += 'media-upload'
                $stages += 'preflight'
                $stages += @(Get-PASComponentStageNames $type | ForEach-Object { $_.ToLowerInvariant() })
            }

            $order = 0
            foreach ($stage in $stages) {
                $order++
                [pscustomobject]@{
                    Component = $type
                    Stage = $stage
                    Order = $order
                }
            }
        }
    }
}
