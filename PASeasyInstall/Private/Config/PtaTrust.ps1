# PVWA talks to PTA over HTTPS, and PTA has a certificate it made itself. In a lab, the first PVWA server of the
# run puts the certificate PTA presents into its trusted roots (recipe Recipes/Pta/Trust-Pta.ps1).

function New-PASPtaTrustWorkflow {
    # Writes one workflow and inventory per PTA of the configuration into the run folder (target
    # 'trust-<pta id>', on the first PVWA server). Returns @{ Target; Workflow; Inventory } in run order.
    # Nothing for the Secure profile: there PTA needs a certificate of a certificate authority.
    param([hashtable]$Config, [string]$RunDirectory)
    $items = @()
    $ptas = @($Config.components | Where-Object { $_ -and $_.type -eq 'PTA' })
    $pvwa = @($Config.components | Where-Object { $_ -and $_.type -eq 'PVWA' })[0]
    if (-not $ptas.Count -or -not $pvwa -or [string]$Config.security.profile -ne 'Lab') {
        return $items
    }
    $recipes = Join-Path (Get-PASModuleRoot) 'Recipes/Pta'
    foreach ($pta in $ptas) {
        $id = 'trust-' + [string]$pta.id
        $base = Join-Path (Join-Path $RunDirectory 'Payloads') $id
        $workflowDirectory = Join-Path $base 'Workflows'
        $workflowPath = Join-Path $workflowDirectory ($id + '.psd1')
        $inventoryPath = Join-Path $RunDirectory ($id + '-inventory.psd1')
        # Written once: on a resume the files of the first start are used again, because the engine pins them.
        if (-not (Test-Path -LiteralPath $workflowPath) -or -not (Test-Path -LiteralPath $inventoryPath)) {
            New-Item -ItemType Directory -Path $workflowDirectory -Force |
                Out-Null
            foreach ($name in @('Trust-Pta.ps1', 'Trust-Verify.ps1')) {
                Copy-Item -LiteralPath (Join-Path $recipes $name) -Destination (Join-Path $base $name) -Force
            }
            $steps = @(@{
                    Id = 'pta-trust'
                    Script = 'Trust-Pta.ps1'
                    Mode = 'Detached'
                    Inputs = @{ Settings = @{ ConfigRef = ('Values.Components.' + $id) } }
                    Verify = 'Trust-Verify.ps1'
                    TimeoutSeconds = 600
                })
            $workflow = @{ SchemaVersion = 1; Name = ('PVWA trust of PTA ' + [string]$pta.id); Target = $id; Root = '..'; Steps = $steps }
            $pvwaInventory = New-PASRuntimeInventory -Config $Config -RunDirectory $RunDirectory -SkipMediaHash -ComponentId ([string]$pvwa.id)
            $inventory = @{ SchemaVersion = 1; Targets = @{ $id = $pvwaInventory.Targets[[string]$pvwa.id] }; Values = @{ Components = @{ $id = @{
                            PtaAddress = [string]$Config.hosts[[string]$pta.host].address
                            PtaName = [string](Get-PASValue $pta 'name' ([string]$pta.id))
                            PtaPort = 443
                            SecurityProfile = [string]$Config.security.profile
                            StageRoot = ('C:\ProgramData\PASeasyInstall\components\' + [string]$pvwa.id)
                        } } } }
            [IO.File]::WriteAllText($workflowPath, (ConvertTo-PASLiteral $workflow), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($inventoryPath, (ConvertTo-PASLiteral $inventory), [Text.UTF8Encoding]::new($false))
        }
        $items += @{ Target = $id; Workflow = $workflowPath; Inventory = $inventoryPath }
    }
    return $items
}
