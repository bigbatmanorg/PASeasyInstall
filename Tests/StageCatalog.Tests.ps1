# Get-PASStageCatalog must list the steps a run really executes: the step ids written by the workflow
# generator (Private\Config\Planning.ps1) for PVWA, CPM, PSM, PSMP and AD, and the Vault workflow files.
BeforeDiscovery {
    $componentTypes = @(@{ Type = 'PVWA' }, @{ Type = 'CPM' }, @{ Type = 'PSM' }, @{ Type = 'PSMP' }, @{ Type = 'AD' })
}
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    function Get-GeneratedStepIds([string]$Type) {
        # Writes the workflow of one component into TestDrive and returns its step ids, in order.
        $runDirectory = Join-Path $TestDrive ('run-' + [guid]::NewGuid().ToString('N'))
        $path = InModuleScope PASeasyInstall -Parameters @{ Type = $Type; RunDirectory = $runDirectory } {
            param($Type, $RunDirectory)
            $component = @{
                id = 'fixture'
                type = $Type
                host = 'host01'
                media = 'C:\media\installer.zip'
                options = @{}
            }
            $configuration = @{ activeDirectory = @{ mode = 'None'; join = @() } }
            New-PASComponentWorkflow -Component $component -Configuration $configuration -RunDirectory $RunDirectory
        }
        $workflow = Import-PowerShellDataFile -Path $path
        return @($workflow.Steps | ForEach-Object { [string]$_.Id })
    }
}

Describe 'Stage catalog of <Type>' -ForEach $componentTypes {
    It 'equals the step ids of the generated workflow' {
        $generated = @(Get-GeneratedStepIds $Type)
        # The catalog leaves out the run-dependent PSM continuations: <stage>-pass2, <stage>-reboot, ...
        $expected = @($generated | Where-Object { $_ -notmatch '-pass\d+(-reboot)?$' -and ($Type -ne 'PSM' -or $_ -notmatch '-reboot$') })
        $catalog = @(Get-PASStageCatalog -Component $Type | Sort-Object Order | ForEach-Object { $_.Stage })
        ($catalog -join ',') | Should -Be ($expected -join ',')
    }
    It 'numbers the stages from 1 without gaps' {
        $orders = @(Get-PASStageCatalog -Component $Type | ForEach-Object { $_.Order })
        ($orders -join ',') | Should -Be ((1..$orders.Count) -join ',')
        @(Get-PASStageCatalog -Component $Type | Where-Object { $_.Component -ne $Type }).Count | Should -Be 0
    }
}

Describe 'Stage catalog of the Vault' {
    It 'lists the step ids of the Primary Vault workflow file' {
        $workflow = Import-PowerShellDataFile -Path (Get-PASTestModulePath 'Recipes/Vault/Workflows/VaultPrimaryOnly.psd1')
        $expected = @($workflow.Steps | ForEach-Object { [string]$_.Id })
        (@(Get-PASStageCatalog -Component Vault | ForEach-Object { $_.Stage }) -join ',') | Should -Be ($expected -join ',')
    }
    It 'lists both DR phases in order' {
        $expected = @()
        foreach ($file in 'VaultDR-Phase1.psd1', 'VaultDR-Phase2.psd1') {
            $workflow = Import-PowerShellDataFile -Path (Get-PASTestModulePath ('Recipes/Vault/Workflows/' + $file))
            $expected += @($workflow.Steps | ForEach-Object { [string]$_.Id })
        }
        (@(Get-PASStageCatalog -Component DR | ForEach-Object { $_.Stage }) -join ',') | Should -Be ($expected -join ',')
    }
    It 'lists the PTA stages with the restart after the vendor installer' {
        $stages = @(Get-PASStageCatalog -Component PTA | ForEach-Object { $_.Stage })
        ($stages -join ',') | Should -Be 'media-upload,preflight,extract,prerequisites,install,register,verify'
    }
}
