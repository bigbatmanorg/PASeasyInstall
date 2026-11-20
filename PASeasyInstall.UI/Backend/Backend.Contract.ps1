# The UI <-> backend seam. The UI calls ONLY these commands; any backend that exports them with
# compatible parameters can be plugged in (the real Orchestrator by default, the Mock for UI work).
#
#   Get-PASMediaInventory        -Path <string[]>            files, folders, ZIP bundles (read-only)
#                                -> @( @{Component; Name; Version; Variant; Path; Entry; Source; Container} )
#                                Component: Vault|PACLI|DR|KeyGen|PVWA|CPM|PSM|PSMP|PTA|License|RecoveryKey|Prerequisite|Unknown|Missing
#   Get-PASMediaSelection        -Inventory <items>           -> @{ Component = chosen item }
#   New-PASDeploymentConfiguration -Environment -VaultMode Primary|PrimaryDR|Existing
#                                -Instances @( @{Type=PVWA|CPM|PSM|PSMP; Name='PVWA01'; Address='10.0.0.21'; Username=''} )
#                                (Name = server hostname; Username optional, else -Username / -LinuxUsername)
#                                -PrimaryUsername -DRUsername (optional per-server accounts for the Vault servers)
#                                -ControllerAddress -PrimaryAddress -DRAddress -ExistingVaultAddress
#                                -Username -LinuxUsername -Media @{Vault=item;..} -ExecutionMode Sequential|Parallel
#                                Parallel: Vault/DR first, then component servers concurrently; the backend
#                                (orchestrator) coordinates Vault registration and sessions.
#                                Several instances per type (PTA: one). Same address = same server, named
#                                after its first instance; CredentialMap keys are those server names.
#                                -SecurityProfile Secure|Lab (Lab = the UI's lab mode: audited lab deviations)
#                                -AcceptEula (PSMP's unattended installer requires explicit EULA acceptance)
#                                -> configuration object (hosts, components[], vault, media, name)
#   Test-PASEnvironment          -Config <path> | -Configuration <obj> [-CheckMedia]
#                                -> @{ Valid; Issues[]; Warnings[]; Configuration }
#   Get-PASEnvironmentPlan       -Configuration <obj>
#                                -> @{ Name; ConfigDigest; ExistingVault; Items[ @{Id;Name;Type;Host;Address;Os;Media;DependsOn[]} ];
#                                      Warnings[]; ExecutionMode }
#   Save-PASEnvironment          -Configuration -Path [-Force] -> full path (refuses overwrite without -Force)
#   Start-PASEnvironment         -Configuration -CredentialMap @{hostId=PSCredential} -SecretMap @{VaultAdmin|VaultMaster|DRPassword=SecureString}
#                                -> RunId (32 hex chars)
#   Get-PASEnvironmentSnapshot   -RunId [-Tail] -> @{ RunId; Status; CurrentComponent; LastStep; ErrorEvents;
#                                      Events[ @{TimestampUtc;Component;Stage;Event;Level;Status;Message} ] }
#                                Event.Status is one of Running | Complete | Failed | Warning | Info.
#   Get-PASStageCatalog          -Component Vault|DR|PVWA|CPM|PSM|PSMP|AD -> @( @{Component;Stage} )
#
# Orchestrator (default) = the real installer from <ModulesRoot>/PASeasyInstall.Orchestrator. A composed
# configuration runs as a set of engine runs: Vault/DR first, then one run per component instance,
# one at a time (Sequential) or concurrently per server (Parallel); Vault sessions stay serialised.
# Mock = in-process dummy for UI work; contacts no server.

$script:PASUIBackendContract = [ordered]@{
    'Get-PASMediaInventory'          = @('Path')
    'Get-PASMediaSelection'          = @('Inventory')
    'New-PASDeploymentConfiguration' = @('Environment','VaultMode','Instances','ControllerAddress','PrimaryAddress','DRAddress','ExistingVaultAddress','Username','LinuxUsername','Media','ExecutionMode','PrimaryUsername','DRUsername','SecurityProfile','AcceptEula')
    'Test-PASEnvironment'            = @('Config','Configuration','CheckMedia')
    'Get-PASEnvironmentPlan'         = @('Configuration')
    'Save-PASEnvironment'            = @('Configuration','Path','Force')
    'Start-PASEnvironment'           = @('Configuration','CredentialMap','SecretMap')
    'Get-PASEnvironmentSnapshot'     = @('RunId','Tail')
    'Get-PASStageCatalog'            = @('Component')
}

function Get-PASUIBackendContract { return $script:PASUIBackendContract }

function Assert-PASUIBackend {
    <# Fails fast, before any window opens, when a plugged-in backend misses part of the contract. #>
    $missing = New-Object System.Collections.ArrayList
    foreach ($name in $script:PASUIBackendContract.Keys) {
        $cmd = Get-Command -Name $name -ErrorAction SilentlyContinue
        if (-not $cmd) { [void]$missing.Add($name); continue }
        foreach ($p in $script:PASUIBackendContract[$name]) {
            if (-not $cmd.Parameters.ContainsKey($p)) { [void]$missing.Add("$name -$p") }
        }
    }
    if ($missing.Count) { throw ('UI backend does not satisfy the contract: ' + ($missing -join ', ')) }
}

function Import-PASUIBackend {
    <#
      Orchestrator : the real PASeasyInstall.Orchestrator. -ModulesRoot defaults to the Modules folder
                     this UI module is installed in.
      Mock         : in-process dummy backend for UI work; no servers, files only where the user saves.
    #>
    param([ValidateSet('Mock','Orchestrator')][string]$Kind = 'Orchestrator', [string]$ModulesRoot = '')
    switch ($Kind) {
        'Mock' {
            Import-Module (Join-Path $PSScriptRoot 'Mock/PASeasyInstall.Mock.psd1') -Force -Global -ErrorAction Stop
        }
        'Orchestrator' {
            if (-not $ModulesRoot) { $ModulesRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
            $manifest = Join-Path $ModulesRoot 'PASeasyInstall.Orchestrator/PASeasyInstall.Orchestrator.psd1'
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "Orchestrator not found: $manifest" }
            Import-Module $manifest -Global -Force -ErrorAction Stop
        }
    }
    Assert-PASUIBackend
    return $Kind
}
