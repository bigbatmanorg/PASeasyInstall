# Shared by the test files. Dot-source it in BeforeAll (and in BeforeDiscovery when discovery needs it):
#     . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
# It defines the repository paths and Import-PASTestModule. It changes nothing on disk.
$PASRepoRoot = Split-Path -Parent $PSScriptRoot
$PASModuleRoot = Join-Path $PASRepoRoot 'PASeasyInstall'
$PASModuleManifest = Join-Path $PASModuleRoot 'PASeasyInstall.psd1'
$PASUIModuleRoot = Join-Path $PASRepoRoot 'PASeasyInstall.UI'
$PASUIModuleManifest = Join-Path $PASUIModuleRoot 'PASeasyInstall.UI.psd1'

function Import-PASTestModule {
    # Imports the core module from the working tree. Private functions are reachable with
    # InModuleScope PASeasyInstall { ... } or Mock -ModuleName PASeasyInstall.
    $manifest = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall') 'PASeasyInstall.psd1'
    Import-Module $manifest -Force -ErrorAction Stop
}

function Get-PASTestModulePath {
    # Full path of a file inside the core module, for example 'Recipes/WindowsComponent/Task.ps1'.
    param([Parameter(Mandatory)][string]$RelativePath)
    return (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall') $RelativePath)
}

function Get-PASTestPrivateProxy {
    # The module exports only its public commands. Tests that call a private function directly, outside
    # InModuleScope, dot-source the result of this function after Import-PASTestModule:
    #     . (Get-PASTestPrivateProxy)
    # It defines, in the caller's scope, one small function per private function of the module. Each one
    # calls the real function inside the module, so Mock -ModuleName PASeasyInstall still applies.
    $module = Get-Module -Name PASeasyInstall
    if (-not $module) {
        throw 'Import-PASTestModule must be called before Get-PASTestPrivateProxy'
    }
    $exported = @($module.ExportedFunctions.Keys)
    $names = @(& $module { Get-Command -CommandType Function | Where-Object { $_.Module -and $_.Module.Name -eq 'PASeasyInstall' } | ForEach-Object { $_.Name } })
    $lines = New-Object System.Collections.ArrayList
    foreach ($name in $names) {
        if ($exported -contains $name -or $name -notmatch '^[A-Za-z]+-[A-Za-z0-9]+$') {
            continue
        }
        [void]$lines.Add("function $name { & (Get-Module -Name PASeasyInstall) { $name @args } @args }")
    }
    return [scriptblock]::Create(($lines -join "`n"))
}
