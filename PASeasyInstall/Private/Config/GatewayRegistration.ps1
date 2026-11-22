# An HTML5 Gateway must be known to PVWA: one entry in the PVWA configuration (a file in the Vault) and a
# reference in every PSM server entry. The vendor has no tool for it, so the recipe
# Recipes/Html5Gateway/Register-Gateway.ps1 changes the file with PACLI, run on the first PVWA server of the lab.

function New-PASGatewayRegistrationWorkflow {
    # Writes one workflow and inventory per HTML5 Gateway of the configuration into the run folder
    # (target 'register-<gateway id>', on the first PVWA server). Returns @{ Target; Workflow; Inventory; Archive }.
    param([hashtable]$Config, [string]$RunDirectory)
    $items = @()
    $gateways = @($Config.components | Where-Object { $_ -and $_.type -eq 'HTML5GW' })
    if (-not $gateways.Count) {
        return $items
    }
    $pvwa = @($Config.components | Where-Object { $_ -and $_.type -eq 'PVWA' })[0]
    $archive = [string](Get-PASValue (Get-PASValue $Config 'options' @{}) 'pacliPackage' '')
    if (-not $pvwa -or -not $archive -or -not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        throw 'The HTML5 Gateway cannot be registered: the lab needs a PVWA and the PACLI package of the media folder'
    }
    $recipes = Get-PASModuleRoot
    $script = [IO.File]::ReadAllText((Join-Path $recipes 'Recipes/Html5Gateway/Register-Gateway.ps1'))
    $script = $script.Replace('# PAEASY_INCLUDE_VAULT_PACLI', [IO.File]::ReadAllText((Join-Path $recipes 'Recipes/Vault/Tasks/Common/PacliTransport.ps1')))
    $workRoot = 'C:\PASeasyInstallGateway'
    foreach ($gateway in $gateways) {
        $id = 'register-' + [string]$gateway.id
        $base = Join-Path (Join-Path $RunDirectory 'Payloads') $id
        $workflowDirectory = Join-Path $base 'Workflows'
        $workflowPath = Join-Path $workflowDirectory ($id + '.psd1')
        $inventoryPath = Join-Path $RunDirectory ($id + '-inventory.psd1')
        # Written once: on a resume the files of the first start are used again, because the engine pins them.
        if (-not (Test-Path -LiteralPath $workflowPath) -or -not (Test-Path -LiteralPath $inventoryPath)) {
            New-Item -ItemType Directory -Path $workflowDirectory -Force |
                Out-Null
            [IO.File]::WriteAllText((Join-Path $base 'Register-Gateway.ps1'), $script, [Text.UTF8Encoding]::new($false))
            Copy-Item -LiteralPath (Join-Path $recipes 'Recipes/Html5Gateway/Register-Verify.ps1') -Destination (Join-Path $base 'Register-Verify.ps1') -Force
            $steps = @(
                @{ Id = 'pacli-upload'; Kind = 'Transfer'; Source = $archive; Destination = ($workRoot + '\PACLI.zip'); TimeoutSeconds = 600 }
                @{
                    Id = 'gateway-register'
                    Script = 'Register-Gateway.ps1'
                    Mode = 'Detached'
                    Inputs = @{ Stage = 'Register'; Settings = @{ ConfigRef = ('Values.Components.' + $id) }; VaultPassword = @{ SecretRef = 'VaultAdmin' } }
                    RequiresVaultSession = $true
                    Verify = 'Register-Verify.ps1'
                    Critical = $true
                    TimeoutSeconds = 900
                }
            )
            $workflow = @{ SchemaVersion = 1; Name = ('HTML5 Gateway registration ' + [string]$gateway.id); Target = $id; Root = '..'; Steps = $steps }
            $pvwaInventory = New-PASRuntimeInventory -Config $Config -RunDirectory $RunDirectory -SkipMediaHash -ComponentId ([string]$pvwa.id)
            $inventory = @{ SchemaVersion = 1; Targets = @{ $id = $pvwaInventory.Targets[[string]$pvwa.id] }; Values = @{ Components = @{ $id = @{
                            GatewayId = [string](Get-PASValue $gateway 'name' ([string]$gateway.id))
                            GatewayAddress = [string](Get-PASValue $gateway 'name' ([string]$gateway.id))
                            GatewayPort = [int](Get-PASValue (Get-PASValue $gateway 'options' @{}) 'port' 443)
                            VaultAddress = [string]$Config.vault.address
                            WorkRoot = $workRoot
                            PacliArchive = ($workRoot + '\PACLI.zip')
                        } } } }
            [IO.File]::WriteAllText($workflowPath, (ConvertTo-PASLiteral $workflow), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($inventoryPath, (ConvertTo-PASLiteral $inventory), [Text.UTF8Encoding]::new($false))
        }
        $items += @{ Target = $id; Workflow = $workflowPath; Inventory = $inventoryPath; Archive = $archive }
    }
    return $items
}
