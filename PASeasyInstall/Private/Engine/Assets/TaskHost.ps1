# PAExec task host. Self-contained and Windows PowerShell 5.1 compatible.
# Used in four ways: in a private local runspace, as a WinRM Invoke-Command script block,
# as an SSH-launched file (-Directory -EmitJson) and inside the detached Scheduled Task runner.
# The task body is materialised as a .ps1 file so that 'exit N' ends the task, not the host,
# and sets $LASTEXITCODE.
param(
    [string]$Code,
    [hashtable]$Parameters,
    [string]$Contract = 'Object',
    [int]$MaxOutput = 20000,
    [string]$Directory = '',
    [switch]$EmitJson,
    [switch]$DeleteInputs,
    [switch]$RequireProtectedInputs
)
function ConvertTo-PAExecHostValue {
    param($Value,[int]$Depth=0)
    if ($null -eq $Value) { return $null }
    if ($Depth -gt 20) { return [string]$Value }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $h=@{}; foreach ($k in @($Value.Keys)) { $h[[string]$k] = ConvertTo-PAExecHostValue $Value[$k] ($Depth+1) }
        return ,$h
    }
    if ($Value -is [System.Array] -or $Value -is [System.Collections.IList]) {
        $a=@(); foreach ($v in $Value) { $a += ,(ConvertTo-PAExecHostValue $v ($Depth+1)) }
        return ,$a
    }
    if ($Value -is [psobject] -and $Value.PSObject.BaseObject -is [System.Management.Automation.PSCustomObject]) {
        $h=@{}; foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-PAExecHostValue $p.Value ($Depth+1) }
        return ,$h
    }
    return [string]$Value
}
function Test-PAExecHostResult {
    param($Item)
    if ($null -eq $Item) { return $false }
    if ($Item -is [System.Management.Automation.ErrorRecord] -or $Item -is [System.Management.Automation.WarningRecord] -or
        $Item -is [System.Management.Automation.VerboseRecord] -or $Item -is [System.Management.Automation.DebugRecord] -or
        $Item -is [System.Management.Automation.InformationRecord]) { return $false }
    if ($Item -is [System.Collections.IDictionary]) {
        return ($Item.Contains('Changed') -or $Item.Contains('Message') -or $Item.Contains('Passed') -or $Item.Contains('Satisfied'))
    }
    if ($Item -is [string] -or $Item -is [ValueType]) { return $false }
    return ($null -ne $Item.PSObject.Properties['Changed'] -or $null -ne $Item.PSObject.Properties['Message'] -or
            $null -ne $Item.PSObject.Properties['Passed'] -or $null -ne $Item.PSObject.Properties['Satisfied'])
}
function Format-PAExecHostRecord {
    param($Item)
    if ($Item -is [System.Management.Automation.ErrorRecord]) { return 'ERROR: ' + [string]$Item }
    if ($Item -is [System.Management.Automation.WarningRecord]) { return 'WARNING: ' + $Item.Message }
    if ($Item -is [System.Management.Automation.VerboseRecord]) { return 'VERBOSE: ' + $Item.Message }
    if ($Item -is [System.Management.Automation.DebugRecord]) { return 'DEBUG: ' + $Item.Message }
    return [string]$Item
}
function Invoke-PAExecHostTask {
    param([string]$Code,[hashtable]$Parameters,[string]$Contract,[int]$MaxOutput)
    $file = Join-Path ([IO.Path]::GetTempPath()) ('paeasy-task-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $builder = New-Object System.Text.StringBuilder
    $truncated = $false
    $terminal = $null
    $exitCode = 0
    try {
        # BOM: Windows PowerShell 5.1 reads BOM-less script files using the ANSI code page.
        [IO.File]::WriteAllText($file,$Code,(New-Object System.Text.UTF8Encoding($true)))
        if ($null -eq $Parameters) { $Parameters = @{} }
        $global:LASTEXITCODE = 0
        $candidate = $null
        & $file @Parameters 2>&1 3>&1 4>&1 5>&1 6>&1 | ForEach-Object {
            $item = $_
            if (Test-PAExecHostResult $item) {
                if ($null -ne $candidate) { $line = Format-PAExecHostRecord $candidate } else { $line = $null }
                $candidate = $item
            } else {
                $line = Format-PAExecHostRecord $item
                if ($null -ne $candidate -and -not ($item -is [System.Management.Automation.ErrorRecord] -or $item -is [System.Management.Automation.WarningRecord] -or $item -is [System.Management.Automation.VerboseRecord] -or $item -is [System.Management.Automation.DebugRecord] -or $item -is [System.Management.Automation.InformationRecord])) {
                    # A later ordinary output object means the structured object was not final.
                    $line = (Format-PAExecHostRecord $candidate) + "`n" + $line
                    $candidate = $null
                }
            }
            if ($null -ne $line) {
                if ($builder.Length -lt $MaxOutput) { [void]$builder.Append($line); [void]$builder.Append("`n") } else { $truncated = $true }
            }
        }
        $exitCode = [int]$global:LASTEXITCODE
        $terminal = $candidate
        $output = $builder.ToString()
        if ($output.Length -gt $MaxOutput) { $output = $output.Substring(0,$MaxOutput); $truncated = $true }
        if ($truncated) { $output += ' [TRUNCATED]' }
        if($Contract -notin @('Object','ExitCode','Check')){throw 'Unsupported task output contract'}
        if($exitCode -ne 0){return @{Ok=$false;Terminal=$null;Output=$output;Error="Task exited with code $exitCode";ExitCode=$exitCode}}
        if ($Contract -eq 'ExitCode') {
            if ($exitCode -ne 0) { return @{ Ok=$false; Terminal=(ConvertTo-PAExecHostValue $terminal); Output=$output; Error="Task exited with code $exitCode"; ExitCode=$exitCode } }
        } elseif ($null -eq $terminal) {
            $why = 'Task contract missing: final output object must be a structured task/check result'
            if ($exitCode -ne 0) { $why += " (task exited with code $exitCode)" }
            return @{ Ok=$false; Terminal=$null; Output=$output; Error=$why; ExitCode=$exitCode }
        }
        $value=ConvertTo-PAExecHostValue $terminal
        $result=@{Ok=$true;Terminal=$value;Output=$output;Error=$null;ExitCode=$exitCode}
        if($Contract -eq 'Check'){
            if($value -isnot [Collections.IDictionary] -or -not $value.Contains('Passed') -or $value.Passed -isnot [bool]){throw 'Check contract requires a boolean Passed'}
            $evidence=@();if($value.Contains('Evidence')){$evidence=@($value.Evidence)}
            if($evidence.Count -gt 32){throw 'Check evidence exceeds its count limit'}
            foreach($entry in $evidence){if($entry -isnot [string] -or $entry.Length -gt 2048){throw 'Check evidence must contain bounded strings'}}
            $message='';if($value.Contains('Message')){if($value.Message -isnot [string] -or $value.Message.Length -gt 4000){throw 'Check message must be a bounded string'};$message=$value.Message}
            $check=@{schemaVersion=1;passed=$value.Passed;message=$message;evidence=$evidence}
            if($value.Contains('SessionClosed')){
                if($value.SessionClosed -isnot [bool]){throw 'Check SessionClosed must be a boolean'}
                $check.sessionClosed=$value.SessionClosed
            }
            $result.Check=$check
        }
        return $result
    } catch {
        $output = $builder.ToString()
        if ($output.Length -gt $MaxOutput) { $output = $output.Substring(0,$MaxOutput) + ' [TRUNCATED]' }
        return @{ Ok=$false; Terminal=$null; Output=$output; Error=([string]$_.Exception.Message); ExitCode=$exitCode }
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}
if ($Directory) {
    try {
        $taskFile = Join-Path $Directory 'task.ps1'
        $inputFile = Join-Path $Directory 'inputs.json'
        $Code = [IO.File]::ReadAllText($taskFile)
        $Parameters = @{}
        $protectedFile=Join-Path $Directory 'inputs.dpapi'
        if(Test-Path -LiteralPath $protectedFile){
            Add-Type -AssemblyName System.Security
            $bytes=$null
            try{
                $entropy=[Text.Encoding]::UTF8.GetBytes((Split-Path $Directory -Leaf))
                $bytes=[Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($protectedFile),$entropy,[Security.Cryptography.DataProtectionScope]::LocalMachine)
                $raw=[Text.Encoding]::UTF8.GetString($bytes)
                $Parameters=ConvertTo-PAExecHostValue (ConvertFrom-Json -InputObject $raw)
            }finally{
                if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}
                $raw=$null
                if($DeleteInputs){Remove-Item -LiteralPath $protectedFile -Force -ErrorAction SilentlyContinue}
            }
        }elseif($RequireProtectedInputs){
            if($DeleteInputs){Remove-Item -LiteralPath $inputFile -Force -ErrorAction SilentlyContinue}
            throw 'Detached encrypted inputs are missing; refusing plaintext fallback'
        }
        elseif (Test-Path -LiteralPath $inputFile) {
            $raw = [IO.File]::ReadAllText($inputFile)
            if ($DeleteInputs) { Remove-Item -LiteralPath $inputFile -Force -ErrorAction SilentlyContinue }
            if ($raw.Trim()) { $Parameters = ConvertTo-PAExecHostValue (ConvertFrom-Json -InputObject $raw) }
            if ($null -eq $Parameters) { $Parameters = @{} }
        }
        $contractFile = Join-Path $Directory 'contract.txt'
        if (Test-Path -LiteralPath $contractFile) { $Contract = ([IO.File]::ReadAllText($contractFile)).Trim() }
        $result = Invoke-PAExecHostTask $Code $Parameters $Contract $MaxOutput
    } catch {
        $result = @{ Ok=$false; Terminal=$null; Output=''; Error=([string]$_.Exception.Message); ExitCode=0 }
    }
} else {
    $result = Invoke-PAExecHostTask $Code $Parameters $Contract $MaxOutput
}
# Sanitize before the detached runner writes stdout/status on the target, not only
# after retrieval by the controller. Only secret-bearing inputs contribute markers.
function Get-PAExecHostSecretMarkers {
    param($Value,[string]$Name='')
    if($Value -is [System.Collections.IDictionary]){
        foreach($key in $Value.Keys){Get-PAExecHostSecretMarkers $Value[$key] ([string]$key)}
    }elseif($Name -match '(?i)password|secret|token|credential'){
        if($Value -is [pscredential]){$Value.GetNetworkCredential().Password}
        elseif($Value -is [Security.SecureString]){([Net.NetworkCredential]::new('',$Value)).Password}
        elseif($Value -is [string] -and $Value){$Value}
    }
}
function Protect-PAExecHostValue {
    param($Value,[string[]]$Markers)
    if($Value -is [string]){
        foreach($marker in $Markers){if($marker){$Value=$Value.Replace($marker,'[REDACTED]')}}
        return $Value
    }
    if($Value -is [System.Collections.IDictionary]){
        $clean=@{};foreach($key in $Value.Keys){$safeKey=Protect-PAExecHostValue ([string]$key) $Markers;$clean[$safeKey]=Protect-PAExecHostValue $Value[$key] $Markers};return ,$clean
    }
    if($Value -is [array]){return ,@(foreach($item in $Value){Protect-PAExecHostValue $item $Markers})}
    return $Value
}
$result=ConvertTo-PAExecHostValue $result
$markers=@(Get-PAExecHostSecretMarkers $Parameters)
$result=Protect-PAExecHostValue $result $markers
if($result.Terminal -is [System.Collections.IDictionary] -and $result.Terminal.Contains('Data') -and $null -ne $result.Terminal.Data){
    $data=$result.Terminal.Data
    $allowed=@('Pacli','SafeName','Cycle','Metadata','RebootRequired','Computer','OS','Build','Hash','TrustBundleSHA256','Version','File')
    $valid=($data -is [System.Collections.IDictionary])
    if($valid){foreach($key in $data.Keys){
        $value=$data[$key]
        if($key -in @('Hash','TrustBundleSHA256') -and $null -ne $value -and ($value -isnot [string] -or $value -notmatch '^[A-Fa-f0-9]{64}$')){$valid=$false;break}
        if($allowed -cnotcontains $key -or ($null -ne $value -and $value -isnot [string] -and $value -isnot [bool] -and $value -isnot [int] -and $value -isnot [long])){$valid=$false;break}
    }}
    if(-not $valid){$result.Ok=$false;$result.Error='Task returned unsupported Data payload';$result.Terminal.Data=$null}
}
$markers=$null
if ($EmitJson) {
    [Console]::Out.WriteLine('PAEASY_RESULT:' + ($result | ConvertTo-Json -Depth 25 -Compress))
} else {
    [pscustomobject]$result
}
