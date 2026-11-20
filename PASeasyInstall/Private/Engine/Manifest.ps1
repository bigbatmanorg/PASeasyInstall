function Get-PAExecPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$WorkflowPath,
        [Parameter(Mandatory=$true)][string]$InventoryPath
    )
    $wfFile = (Resolve-Path -LiteralPath $WorkflowPath -ErrorAction Stop).ProviderPath
    $invFile = (Resolve-Path -LiteralPath $InventoryPath -ErrorAction Stop).ProviderPath
    # Import-PowerShellDataFile evaluates only restricted-language data; no script code runs while planning.
    $wf = Import-PowerShellDataFile -Path $wfFile
    $inventory = Import-PowerShellDataFile -Path $invFile
    if ([int](Get-PSObjectValue $wf 'SchemaVersion' 0) -ne 1) { throw 'Unsupported workflow schema version (expected 1)' }
    if ([int](Get-PSObjectValue $inventory 'SchemaVersion' 0) -ne 1) { throw 'Unsupported inventory schema version (expected 1)' }
    $name = [string](Get-PSObjectValue $wf 'Name')
    $targetName = [string](Get-PSObjectValue $wf 'Target')
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($targetName)) { throw 'Workflow Name and Target are required' }
    if ($targetName -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$') { throw "Invalid target name '$targetName'" }
    if (-not $inventory.Contains('Targets') -or -not $inventory.Targets.Contains($targetName)) { throw "Inventory target '$targetName' not found" }
    $target = $inventory.Targets[$targetName]
    $protocol = [string](Get-PSObjectValue $target 'Protocol')
    if ($protocol -notin @('Local','WinRM','SSH')) { throw "Unsupported protocol: '$protocol'" }
    if ($protocol -ne 'Local' -and [string]::IsNullOrWhiteSpace([string](Get-PSObjectValue $target 'ComputerName'))) { throw 'Remote target requires ComputerName' }
    if ($protocol -eq 'SSH' -and [string]::IsNullOrWhiteSpace([string](Get-PSObjectValue $target 'User'))) { throw 'SSH target requires User' }
    $defaultRuntime = 'WindowsPowerShell'; if ($protocol -eq 'Local') { $defaultRuntime = 'PowerShell' }
    $runtime = [string](Get-PSObjectValue $target 'Runtime' $defaultRuntime)
    if ($runtime -notin @('WindowsPowerShell','PowerShell','Bash')) { throw "Unsupported target runtime: $runtime" }
    if ($protocol -eq 'Local' -and $runtime -eq 'Bash') { throw 'Local Bash runtime is not supported; use SSH' }
    if (-not $target.Contains('Runtime')) { $target['Runtime'] = $runtime }
    $steps = @(Get-PSObjectValue $wf 'Steps' @())
    if ($steps.Count -eq 0) { throw "Workflow '$name' has no steps" }
    $ids = @{}
    $digestFiles = @($wfFile,$invFile)
    $root = Split-Path -Parent $wfFile
    if ($wf.Contains('Root')) {
        $root = [IO.Path]::GetFullPath((Join-Path $root ([string]$wf.Root)))
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Workflow Root does not exist' }
    }
    foreach ($s in $steps) {
        if ($s -isnot [System.Collections.IDictionary]) { throw 'Every workflow step must be a hashtable' }
        $id = [string](Get-PSObjectValue $s 'Id')
        if ($id -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}$' -or $ids.ContainsKey($id)) { throw "Invalid or duplicated task ID: '$id'" }
        $ids[$id] = $true
        $kind = [string](Get-PSObjectValue $s 'Kind' 'Script')
        if ($kind -notin @('Script','Transfer','Relay','Reboot','Wait','Verify')) { throw "Invalid kind '$kind' for $id" }
        foreach($reference in @('RebootFromAttempt','RebootRequiredFrom')){
            $source=[string](Get-PSObjectValue $s $reference '')
            if($source -and ($kind -ne 'Reboot' -or $source -eq $id -or -not $ids.ContainsKey($source))){throw 'Reboot evidence must reference an earlier workflow task'}
        }
        $mode=[string](Get-PSObjectValue $s 'Mode' 'Direct')
        if($kind -eq 'Verify' -and ($mode -ne 'Direct' -or -not(Get-PSObjectValue $s 'Verify' '') -or (Get-PSObjectValue $s 'Script' ''))){throw 'Read-only Verify steps require only a verification script in Direct mode'}
        if($s.Contains('RequiresVaultSession')){
            if($s.RequiresVaultSession -isnot [bool]){throw 'RequiresVaultSession must be a Boolean'}
            if($s.RequiresVaultSession -and ($kind -ne 'Script' -or $mode -ne 'Detached' -or -not(Get-PSObjectValue $s 'Verify' ''))){throw 'Vault session steps require a detached script and independent verification'}
            if($s.RequiresVaultSession -and (Get-PSObjectValue $s 'Probe' '')){throw 'Authenticated actions cannot use a skipping direct probe'}
        }
        if ($mode -notin @('Direct','Detached')) { throw "Invalid execution mode '$mode' for $id" }
        if ($mode -eq 'Detached' -and $kind -ne 'Script') { throw "Detached supported for Script tasks only: $id" }
        $principalRef=[string](Get-PSObjectValue $s 'TaskPrincipalCredentialRef' '')
        if($principalRef -and ($principalRef -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$' -or $mode -ne 'Detached' -or $kind -ne 'Script' -or $protocol -ne 'WinRM' -or $runtime -eq 'Bash')){throw 'Task principal references require a Windows detached script'}
        $scope=[string](Get-PSObjectValue $s 'Scope' 'Target')
        $verifyMode=[string](Get-PSObjectValue $s 'VerifyMode' 'Direct')
        if($verifyMode -notin @('Direct','Detached')){throw 'Invalid VerifyMode'}
        if($verifyMode -eq 'Detached' -and ($kind -notin @('Script','Verify') -or $scope -ne 'Target' -or $protocol -ne 'WinRM' -or $runtime -eq 'Bash' -or -not(Get-PSObjectValue $s 'Verify' ''))){throw 'Detached verification requires a Windows target and an explicit verification script'}
        if($s.Contains('VerifyRequiresVaultSession')){
            if($s.VerifyRequiresVaultSession -isnot [bool]){throw 'VerifyRequiresVaultSession must be a Boolean'}
            if($s.VerifyRequiresVaultSession -and ($verifyMode -ne 'Detached' -or (Get-PSObjectValue $s 'Probe' ''))){throw 'Authenticated verification requires a detached check without a skipping probe'}
        }
        if ($scope -notin @('Controller','Target')) {throw "Invalid Script scope on $id"}
        if ($mode -eq 'Detached' -and $scope -eq 'Controller') { throw "Controller-scoped step cannot be detached: $id" }
        $contract=[string](Get-PSObjectValue $s 'OutputContract' 'Object')
        if ($contract -notin @('Object','ExitCode')) { throw "Invalid OutputContract '$contract' for $id" }
        if ($kind -eq 'Script') {
            $scriptPath = Assert-PSProjectPath $root ([string](Get-PSObjectValue $s 'Script'))
            $digestFiles += @((Get-PSRecipePayload $scriptPath).Files)
            $isShell = $scriptPath -match '\.(sh|bash)$'
            $bashScoped = ($runtime -eq 'Bash' -and $scope -eq 'Target')
            if ($bashScoped -and -not $isShell) { throw "Bash target step '$id' requires a .sh script" }
            if (-not $bashScoped -and $scriptPath -notmatch '\.ps1$') { throw "PowerShell step '$id' requires a .ps1 script" }
        }
        foreach ($field in @('Probe','Verify','RecoveryScript','BeforeTransfer')) {
            $p=[string](Get-PSObjectValue $s $field '')
            if ($p) { $digestFiles += @((Get-PSRecipePayload (Assert-PSProjectPath $root $p)).Files) }
        }
        if((Get-PSObjectValue $s 'BeforeTransfer' '') -and ($kind -ne 'Transfer' -or (Get-PSObjectValue $s 'Direction' 'Upload') -ne 'Upload' -or $runtime -eq 'Bash')){throw 'BeforeTransfer requires a Windows upload transfer'}
        if ((Get-PSObjectValue $s 'RecoveryScript') -and $mode -ne 'Detached') { throw "RecoveryScript requires Mode='Detached' on $id" }
        if ($kind -eq 'Relay' -and (-not (Get-PSObjectValue $s 'SourceTarget') -or -not (Get-PSObjectValue $s 'Files'))) {throw "Relay '$id' requires SourceTarget and Files"}
        if ($kind -eq 'Relay' -and -not $inventory.Targets.Contains([string]$s.SourceTarget)) { throw "Relay '$id' source target '$($s.SourceTarget)' is not in inventory" }
        if ($kind -eq 'Wait' -and -not (Get-PSObjectValue $s 'Milestone')) { throw "Wait task '$id' missing Milestone" }
        foreach ($m in @(@(Get-PSObjectValue $s 'Publishes' @()) + @(Get-PSObjectValue $s 'DependsOn' @()) + @(Get-PSObjectValue $s 'Milestone' @()))) {
            if ($null -ne $m -and [string]$m -notmatch '^[a-zA-Z0-9_.-]+$') { throw "Invalid milestone name '$m' on $id" }
        }
        if ($kind -eq 'Transfer') {
            if ((Get-PSObjectValue $s 'Direction' 'Upload') -notin @('Upload','Download')) { throw "Invalid Transfer Direction for $id" }
            if (-not (Get-PSObjectValue $s 'Source') -or -not (Get-PSObjectValue $s 'Destination')) { throw "Transfer '$id' missing Source/Destination" }
        }
        $timeout=[int](Get-PSObjectValue $s 'TimeoutSeconds' 1800)
        if ($timeout -le 0 -or $timeout -gt 172800) { throw "Invalid TimeoutSeconds on $id" }
        if ($kind -eq 'Script' -and (Get-PSObjectValue $s 'Critical' $false) -and -not (Get-PSObjectValue $s 'Verify')) { throw "Critical step '$id' requires Verify" }
    }
    return [pscustomobject]@{
        WorkflowPath=$wfFile; InventoryPath=$invFile; Workflow=$wf; Inventory=$inventory
        Root=$root; Name=$name; TargetName=$targetName; Target=$target; Runtime=$runtime
        Steps=$steps; Digest=(Get-PSDigest $digestFiles)
    }
}
function Test-PAExecEnvironment {
    [CmdletBinding()]
    param([ValidateSet('Local','WinRM','SSH')][string]$Protocol='Local', [ValidateSet('WindowsPowerShell','PowerShell','Bash')][string]$Runtime='PowerShell',[switch]$Detached)
    $issues=@()
    $notes=@()
    if ($Protocol -eq 'WinRM' -and -not (Test-PSWindows)) { $issues += 'WinRM requires a Windows controller' }
    if ($Protocol -eq 'SSH' -and -not (Get-Command ssh -ErrorAction SilentlyContinue)) { $issues += 'ssh executable not found' }
    if ($Protocol -eq 'SSH' -and -not (Get-Command scp -ErrorAction SilentlyContinue)) { $issues += 'scp executable not found' }
    if ($Protocol -eq 'SSH' -and $Detached -and $Runtime -ne 'Bash') { $issues += 'SSH detached execution requires Bash and root/systemd on the target' }
    if ($Runtime -eq 'WindowsPowerShell' -and -not (Test-PSWindows) -and $Protocol -eq 'Local') { $issues += 'WindowsPowerShell is not available locally on Linux' }
    if ($Runtime -eq 'Bash' -and $Protocol -ne 'SSH') { $issues += 'Bash runtime requires SSH' }
    return [pscustomobject]@{
        PSVersion=[string]$PSVersionTable.PSVersion; Edition=[string]$PSVersionTable.PSEdition; OS=$(if (Test-PSWindows) { 'Windows' } else { 'NonWindows' })
        Protocol=$Protocol; Runtime=$Runtime; Detached=[bool]$Detached; Supported=($issues.Count -eq 0); Issues=$issues; Notes=$notes
    }
}
