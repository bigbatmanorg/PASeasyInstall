# The UI <-> backend seam. The UI calls ONLY the commands listed here: the public commands of the
# PASeasyInstall module. The list holds, per command, the parameter names the UI relies on.
#
#   Get-PASMediaInventory        -Path <string[]>     files, folders, ZIP bundles (read-only)
#                                -> items: Component, Name, Version, Variant, Path, Entry
#   Get-PASMediaSelection        -Inventory <items>   -> @{ Component = recommended item }
#   New-PASLabConfiguration      -Environment -VaultMode Primary|PrimaryDR|Existing
#                                -Instances @( @{Type='PVWA';Name='PVWA01';Address='10.0.0.21';Username=''} )
#                                -ControllerAddress -PrimaryAddress -DRAddress -ExistingVaultAddress
#                                -Username -LinuxUsername -PrimaryUsername -DRUsername -Media @{Vault=item;..}
#                                -SecurityProfile Secure|Lab -AcceptEula
#                                -> configuration (hashtable)
#   Test-PASLabConfiguration     -Configuration <cfg> [-CheckMedia] -> Valid, Issues, Warnings, Configuration
#   Get-PASLabPlan               -Configuration <cfg>
#                                -> Items (Id, Type, Host, Name, Address, Os, Media, DependsOn), Warnings, ExistingVault
#   Get-PASCredentialRequirement -Configuration <cfg>
#                                -> objects: Kind (Credential|Secret), Key, HostId, User, Os, Label
#   Export-PASLabConfiguration   -Configuration -Path [-Force]   writes the project file, returns its full path
#   Import-PASLabConfiguration   -Path                           -> configuration (hashtable)
#   Install-PASLab               -Configuration -CredentialMap @{Key=PSCredential} -SecretMap @{Key=SecureString}
#                                -> run id
#   Get-PASRun                   -RunId [-Tail]
#                                -> RunId, Name, Status, CurrentComponent, Message, LastStep, ErrorEvents, RunDirectory,
#                                   Components (Id, Type, Status, Message),
#                                   Events (TimestampUtc, Component, Stage, Event, Level, Status, Message)
#                                Run status: Launching, Running, Succeeded, Failed, LaunchFailed, Unknown,
#                                Interrupted, Blocked, Abandoned.
#   Get-PASRunEvent              -RunId [-Tail]
#   Get-PASStageCatalog          -Component Vault|DR|PVWA|CPM|PSM|PSMP|AD -> objects: Component, Stage, Order
#   Resume-PASRun                -RunId [-RetryStep] [-CredentialMap] [-SecretMap]
#   Stop-PASRun                  -RunId
#   Export-PASDiagnostics        -RunId -Path [-Force]
#   Test-PASPreflight            -Configuration [-LabPassword | -CredentialMap]
#                                -> rows: Server, Address, Check, Passed, Detail
#   Test-PASHealth               -Configuration | -Path, -VaultCredential [-DRCredential]
#                                -> Healthy, Message, Issues, Components (User, Address, LoggedOn, Version)
#   Install-PASLab and Resume-PASRun also take -LabPassword (one password for everything).
#
# Backends:
#   Live  the PASeasyInstall module this desktop is part of.
#   Mock  Backend/Mock: the same module for everything that only computes; the run, the server
#         check and the lab check are simulated.

$script:PASUIBackendContract = [ordered]@{
    'Get-PASMediaInventory' = @('Path')
    'Get-PASMediaSelection' = @('Inventory')
    'New-PASLabConfiguration' = @('Environment', 'VaultMode', 'Instances', 'ControllerAddress', 'PrimaryAddress', 'DRAddress',
        'ExistingVaultAddress', 'Username', 'LinuxUsername', 'PrimaryUsername', 'DRUsername',
        'Media', 'SecurityProfile', 'AcceptEula')
    'Test-PASLabConfiguration' = @('Configuration', 'CheckMedia')
    'Get-PASLabPlan' = @('Configuration')
    'Get-PASCredentialRequirement' = @('Configuration')
    'Export-PASLabConfiguration' = @('Configuration', 'Path', 'Force')
    'Import-PASLabConfiguration' = @('Path')
    'Install-PASLab' = @('Configuration', 'CredentialMap', 'SecretMap', 'LabPassword')
    'Get-PASRun' = @('RunId', 'Tail')
    'Get-PASRunEvent' = @('RunId', 'Tail')
    'Get-PASStageCatalog' = @('Component')
    'Resume-PASRun' = @('RunId', 'RetryStep', 'CredentialMap', 'SecretMap', 'LabPassword')
    'Stop-PASRun' = @('RunId')
    'Export-PASDiagnostics' = @('RunId', 'Path', 'Force')
    'Test-PASPreflight' = @('Configuration', 'CredentialMap', 'LabPassword')
    'Test-PASHealth' = @('Path', 'Configuration', 'VaultCredential', 'DRCredential')
}

function Get-PASUIBackendContract {
    return $script:PASUIBackendContract
}

function Get-PASUICoreModule {
    <# What to hand to Import-Module for the PASeasyInstall module: the manifest of the module this
       desktop is part of (this file is <module>\Desktop\Backend\Backend.Contract.ps1). #>
    $manifest = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'PASeasyInstall.psd1'
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "The PASeasyInstall module manifest was not found: $manifest"
    }
    return $manifest
}

function Assert-PASUIBackend {
    <# Fails fast, before any window opens, when the imported backend misses a command or a parameter. #>
    $missing = New-Object System.Collections.ArrayList
    foreach ($name in $script:PASUIBackendContract.Keys) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue
        if (-not $command) {
            [void]$missing.Add($name)
            continue
        }
        foreach ($parameter in $script:PASUIBackendContract[$name]) {
            if (-not $command.Parameters.ContainsKey($parameter)) {
                [void]$missing.Add("$name -$parameter")
            }
        }
    }
    if ($missing.Count) {
        throw ('The backend does not satisfy the UI contract. Missing: ' + ($missing -join ', '))
    }
}

function Import-PASUIBackend {
    <# Imports the backend commands and checks them against the contract. Returns the kind.
       No -Global: the commands are imported into the session state this file was dot-sourced in
       (the UI module's, or the script scope of the process that hosts the window), which is where
       every UI function and callback resolves them. Nothing is added to, or replaced in, the
       global scope of a PowerShell session that has the real module loaded. #>
    param([ValidateSet('Live', 'Mock')][string]$Kind = 'Live')
    Import-Module (Get-PASUICoreModule) -ErrorAction Stop
    if ($Kind -eq 'Mock') {
        # Imported after the real module, so its simulated run commands are the ones found by name.
        Import-Module (Join-Path (Join-Path $PSScriptRoot 'Mock') 'PASeasyInstall.Mock.psd1') -Force -ErrorAction Stop
    }
    Assert-PASUIBackend
    return $Kind
}
