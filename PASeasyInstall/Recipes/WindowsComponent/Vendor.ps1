# Exact informational native status from the supplied, independently hashed v15.0/v15.2 PSM source.
function Test-PASeasyPinnedRegImportInfo {
    param([Parameter(Mandatory)]$Record)
    try {
        $id = ([string]$Record.FullyQualifiedErrorId).Split(',')[0]
        if ($id -notin @('NativeCommandError', 'NativeCommandErrorMessage')) { return $false }
        $status = 'The operation completed successfully.'
        if (([string]$Record.Exception.Message).Trim() -cne $status) { return $false }
        if ($null -ne $Record.TargetObject -and
            ($Record.TargetObject -isnot [string] -or
            (-not [string]::IsNullOrWhiteSpace($Record.TargetObject) -and
            $Record.TargetObject.Trim() -cne $status))) { return $false }
        if ($Record.ErrorDetails -and
            ((-not [string]::IsNullOrWhiteSpace($Record.ErrorDetails.Message) -and
                $Record.ErrorDetails.Message.Trim() -cne $status) -or
            -not [string]::IsNullOrWhiteSpace($Record.ErrorDetails.RecommendedAction))) { return $false }
        $where = $Record.InvocationInfo
        if (-not $where -or
            [IO.Path]::GetFileName([string]$where.ScriptName) -cne 'InstallationCommon.ps1' -or
            $where.ScriptLineNumber -ne 699 -or
            [string]$where.Line -notmatch '^\s*\$rc\s*=\s*Reg\s+import\s+\$RegistryBackupPath\s*$') { return $false }
        if (-not(Test-Path -LiteralPath $where.ScriptName -PathType Leaf)) { return $false }
        # Reviewed InstallationCommon.ps1 builds: 15.0 and 15.2.2 (identical code; only the Authenticode block differs).
        $reviewed = @('5CB31809DFD0A16A3AD0EBA2DCC1E1E5A1BE9121696738A0DE40CC0F3D6E21BA', '1E9B54FD138C590C38B346976DF822F0431E32F9157D399B041A00E6B7BDFBBB')
        return ((Get-FileHash -LiteralPath $where.ScriptName -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant() -in $reviewed)
    } catch { return $false }
}
# Vendor scripts use relative modules/configuration paths. Parameter names must be splatted
# as a dictionary: an array containing '-name' passes strings positionally to a PS script.
function Invoke-VendorScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [hashtable]$Parameters = @{},
        [ValidateSet('Success', 'Information')][string]$ResultSource = 'Success',
        [switch]$AllowEmptyNativeStderr,
        [switch]$AllowPinnedRegImportSuccess
    )
    if ($AllowEmptyNativeStderr -and
        ($env:PAEASY_DETACHED_ATTEMPT -notmatch '^[0-9a-f]{32}$' -or
        $env:PAEASY_DETACHED_PROCESS_ID -cne [string]$PID)) { throw 'Native stderr compatibility requires the dedicated detached worker context' }
    if ($AllowPinnedRegImportSuccess -and
        (-not $AllowEmptyNativeStderr -or
        [IO.Path]::GetFileName($ScriptPath) -ine 'Execute-Stage.ps1' -or
        -not $Parameters.ContainsKey('configFilePath') -or
        [string]$Parameters.configFilePath -notmatch '[\\/](?:Hardening[\\/]HardeningConfig|PostInstallation[\\/]PostInstallationConfig)[.]xml$')) { throw 'Pinned registry status compatibility is restricted to the dedicated PSM Harden/PostInstall stages' }
    $global:LASTEXITCODE = 0
    $location = Get-Location
    $previousErrorPreference = $ErrorActionPreference
    $previousGlobalPreference = (Get-Variable -Name ErrorActionPreference -Scope Global).Value
    $scriptPreference = Get-Variable -Name ErrorActionPreference -Scope Script -ErrorAction SilentlyContinue
    $hadScriptPreference = ($null -ne $scriptPreference)
    $previousScriptPreference = if ($hadScriptPreference) { $scriptPreference.Value }else { $null }
    $previousVaultPassword = [Environment]::GetEnvironmentVariable('VAULT_PASSWORD', 'Process')
    try {
        Set-Location -LiteralPath (Split-Path -Parent $ScriptPath)
        if ($AllowEmptyNativeStderr) {
            $ErrorActionPreference = 'Continue'
            $script:ErrorActionPreference = 'Continue'
            $global:ErrorActionPreference = 'Continue'
        }
        $captured = @(& $ScriptPath @Parameters 2>&1 6>&1)
        $output = @($captured | Where-Object { $_ -isnot [Management.Automation.InformationRecord] })
        $information = @($captured | Where-Object { $_ -is [Management.Automation.InformationRecord] })
        $code = $LASTEXITCODE
    } finally {
        if ($AllowEmptyNativeStderr) {
            $global:ErrorActionPreference = $previousGlobalPreference
            if ($hadScriptPreference) { $script:ErrorActionPreference = $previousScriptPreference }else { Remove-Variable -Name ErrorActionPreference -Scope Script -ErrorAction SilentlyContinue }
        }
        $ErrorActionPreference = $previousErrorPreference
        [Environment]::SetEnvironmentVariable('VAULT_PASSWORD', $previousVaultPassword, 'Process')
        Set-Location -LiteralPath $location.Path
    }
    $errors = @($captured | Where-Object { $_ -is [Management.Automation.ErrorRecord] })
    $regInfoCount = 0
    foreach ($record in $errors) {
        if ($AllowPinnedRegImportSuccess -and (Test-PASeasyPinnedRegImportInfo $record)) {
            $regInfoCount++
            continue
        }
        $nativeId = ([string]$record.FullyQualifiedErrorId).Split(',')[0]
        $targetIsBlank = ($null -eq $record.TargetObject -or
            ($record.TargetObject -is [string] -and
            [string]::IsNullOrWhiteSpace($record.TargetObject)))
        $detailsAreBlank = ($null -eq $record.ErrorDetails -or
            ([string]::IsNullOrWhiteSpace([string]$record.ErrorDetails.Message) -and
            [string]::IsNullOrWhiteSpace([string]$record.ErrorDetails.RecommendedAction)))
        if (-not($AllowEmptyNativeStderr -and
                $nativeId -in @('NativeCommandError', 'NativeCommandErrorMessage') -and
                [string]::IsNullOrWhiteSpace([string]$record.Exception.Message) -and
                $targetIsBlank -and
                $detailsAreBlank)) {
            $kind = if ($nativeId -in @('NativeCommandError', 'NativeCommandErrorMessage')) { $nativeId }else { 'PowerShellError' }
            $file = ''
            $line = 0
            if ($record.InvocationInfo) {
                $file = [IO.Path]::GetFileName([string]$record.InvocationInfo.ScriptName)
                $line = [int]$record.InvocationInfo.ScriptLineNumber
            }
            if (-not $file -or $file -notmatch '^[A-Za-z0-9_. -]{1,120}$') { $file = '<script>' }
            throw ('Vendor script emitted an error ({0}, {1}:{2}, captured={3}); inspect its protected local log' -f $kind, $file, $line, $errors.Count)
        }
    }
    $output = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] })
    if ($code -ne 0) { throw "Vendor script $([IO.Path]::GetFileName($ScriptPath)) exited $code" }
    if ($ResultSource -eq 'Information') {
        # Supplied v15 CPM_Hardening emits its final JSON through Write-Host only.
        # Inspect that explicit result channel in memory; never infer success from log phrases.
        $output = @(foreach ($record in $information) {
                try {
                    $candidate = [string]$record.MessageData | ConvertFrom-Json -ErrorAction Stop
                    if ($candidate -and $candidate.PSObject.Properties['isSucceeded']) { $candidate }
                } catch {}
            })
    }
    if (-not $output.Count) { throw "Vendor script $([IO.Path]::GetFileName($ScriptPath)) produced no structured installation result" }
    $value = $output[-1]
    if ($value -is [string]) {
        try { $value = $value | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'Vendor script did not return expected JSON; inspect its protected local log' }
    }
    if ($null -eq $value -or
        ($value -is [System.Collections.IDictionary] -and
        -not $value.Contains('isSucceeded')) -or
        ($value -isnot [System.Collections.IDictionary] -and
        -not $value.PSObject.Properties['isSucceeded'])) { throw 'Vendor result lacks isSucceeded' }
    $success = 0
    if (-not [int]::TryParse([string]$value.isSucceeded, [ref]$success) -or
        $success -ne 0) { throw "Vendor stage failed: $([IO.Path]::GetFileName($ScriptPath)) (see its protected local log)" }
    if ($regInfoCount) { Write-Information -MessageData 'PASeasyInstall INFO: accepted exact informational reg import status from pinned v15 PSM source; independent TLS postconditions remain required' -InformationAction Continue }
    return $value
}
