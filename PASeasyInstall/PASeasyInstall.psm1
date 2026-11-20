# PASeasyInstall: installs CyberArk PAM self-hosted labs from one Windows PowerShell 5.1 controller.
# Not affiliated with CyberArk. Built for labs; production use is at your own risk.
#
# Layout of this module:
#   Public\    one file per exported command (the whole command line surface)
#   Private\   Common (helpers), Config (configuration, planning), Media, Engine (transports, steps,
#              journals), Run (run controller, events), Diagnostics (health, export)
#   Recipes\   scripts that run on the target servers, one folder per component family
#   Controllers\  entry script of the detached run controller process
#
# The desktop wizard is a separate module (PASeasyInstall.UI) that only calls the Public commands.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:PASRoot = $PSScriptRoot
$script:PASEngineRoot = Join-Path $PSScriptRoot 'Private\Engine'

# Private files are loaded in dependency order; Public files in any order.
$privateFiles = @(
    'Common\Common.ps1'
    'Common\Paths.ps1'
    'Common\ModulePaths.ps1'
    'Common\Secrets.ps1'
    'Media\Media.ps1'
    'Media\MediaInventory.ps1'
    'Media\VaultProfile.ps1'
    'Config\Configuration.ps1'
    'Config\Composition.ps1'
    'Config\Credentials.ps1'
    'Config\Planning.ps1'
    'Engine\RecipePayload.ps1'
    'Engine\Manifest.ps1'
    'Engine\Adapters.ps1'
    'Engine\LinuxDetached.ps1'
    'Engine\WindowsStaging.ps1'
    'Engine\Detached.ps1'
    'Engine\DurableCheck.ps1'
    'Engine\Locks.ps1'
    'Engine\Engine.ps1'
    'Run\Events.ps1'
    'Run\Bootstrap.ps1'
    'Run\Run.ps1'
    'Diagnostics\Health.ps1'
    'Diagnostics\Diagnostics.ps1'
    'Diagnostics\Export.ps1'
)
# Recipe helper that the controller also uses locally (ZIP extraction with path checks).
. (Join-Path $PSScriptRoot 'Recipes\WindowsComponent\Archive.ps1')
foreach ($file in $privateFiles) {
    $path = Join-Path (Join-Path $PSScriptRoot 'Private') $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "PASeasyInstall is incomplete: $path is missing" }
    . $path
}

$publicFiles = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -File)
foreach ($file in $publicFiles) { . $file.FullName }
Export-ModuleMember -Function @($publicFiles | ForEach-Object { $_.BaseName })
