# PAExec private utilities. No classes, syntax or APIs requiring PowerShell 7.
function Test-PASWindows { return ($env:OS -eq 'Windows_NT') }
function Get-PASNow { return [DateTime]::UtcNow.ToString('o') }
function Get-PASUtf8NoBom { return (New-Object System.Text.UTF8Encoding($false)) }
function ConvertTo-PASHashtable {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($Value.Keys)) { $h[[string]$k] = ConvertTo-PASHashtable $Value[$k] }
        return , $h
    }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Array] -or $Value -is [System.Collections.IList]) {
        # Remoting deserializes arrays as ArrayList; treat every list as an array.
        $items = @()
        foreach ($v in $Value) { $items += , (ConvertTo-PASHashtable $v) }
        return , $items
    }
    $isCustom = $false
    if ($Value -is [psobject]) {
        $isCustom = ($Value.PSObject.BaseObject -is [System.Management.Automation.PSCustomObject]) -or (@($Value.PSObject.TypeNames | Where-Object { $_ -like 'Deserialized.*' }).Count -gt 0)
    }
    if ($isCustom) {
        $h = @{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-PASHashtable $p.Value }
        return , $h
    }
    return $Value
}
function Get-PASPath {
    param([string]$Base, [string]$Relative)
    if ([IO.Path]::IsPathRooted($Relative)) { return [IO.Path]::GetFullPath($Relative) }
    return [IO.Path]::GetFullPath((Join-Path $Base $Relative))
}
function Assert-PASProjectPath {
    param([string]$Base, [string]$Relative)
    if ([string]::IsNullOrWhiteSpace($Relative)) { throw 'Missing file path' }
    if ([IO.Path]::IsPathRooted($Relative)) { throw "Absolute script path forbidden in workflow: $Relative" }
    $root = [IO.Path]::GetFullPath($Base).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $full = Get-PASPath $Base $Relative
    $comparison = [StringComparison]::Ordinal
    if (Test-PASWindows) { $comparison = [StringComparison]::OrdinalIgnoreCase }
    if (-not $full.StartsWith($root, $comparison)) { throw "Script path escapes workflow directory: $Relative" }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Script file missing: $Relative" }
    return $full
}
function Read-PASJournal {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    try { $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop }
    catch { throw "PAExecCorrupt: cannot parse JSON journal '$Path': $($_.Exception.Message)" }
    if ($null -eq $parsed) { throw "PAExecCorrupt: empty JSON journal '$Path'" }
    return (ConvertTo-PASHashtable $parsed)
}
function Write-PASJournal {
    param([string]$Path, $Object)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($tmp, ($Object | ConvertTo-Json -Depth 30 -Compress), (Get-PASUtf8NoBom))
        $attempt = 0
        while ($true) {
            try {
                # PowerShell converts $null to '' for string parameters; NullString keeps a real null.
                if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }
                else { [IO.File]::Move($tmp, $Path) }
                break
            } catch [System.IO.IOException] {
                # Readers (event tailers, antivirus) can briefly hold the destination on Windows.
                $attempt++
                if ($attempt -ge 20) { throw }
                Start-Sleep -Milliseconds 100
            } catch [System.UnauthorizedAccessException] {
                $attempt++
                if ($attempt -ge 20) { throw }
                Start-Sleep -Milliseconds 100
            }
        }
    } finally { if ([IO.File]::Exists($tmp)) { [IO.File]::Delete($tmp) } }
}
function Protect-PASText {
    param([string]$Text, [object[]]$Redactions)
    if ($null -eq $Text) { return $Text }
    $result = $Text
    foreach ($value in @($Redactions)) {
        if ($null -ne $value -and ([string]$value).Length -ge 4) {
            $result = $result.Replace([string]$value, '***')
            # Secrets can also appear JSON-escaped once an event line is serialized.
            $escaped = (ConvertTo-Json -InputObject ([string]$value) -Compress).Trim('"')
            if ($escaped -ne [string]$value) { $result = $result.Replace($escaped, '***') }
        }
    }
    return $result
}
function Add-PASEvent {
    param([hashtable]$Context, [string]$Type, [string]$TaskId, [string]$Message, [string]$Status = 'Information')
    $Context.Seq = [int]$Context.Seq + 1
    $safeMessage = Protect-PASText (Limit-PASText $Message 4000) $Context.Redactions
    $record = [ordered]@{
        schemaVersion = 1; timestampUtc = (Get-PASNow); sequence = $Context.Seq
        runId = $Context.RunId; target = $Context.TargetName; taskId = $TaskId
        type = $Type; level = $Status; message = $safeMessage
    }
    $line = Protect-PASText ($record | ConvertTo-Json -Compress -Depth 10) $Context.Redactions
    # ConvertTo-Json escapes control characters, so one event is always one physical line.
    [IO.File]::AppendAllText((Join-Path $Context.RunDirectory 'events.jsonl'), $line + "`n", (Get-PASUtf8NoBom))
    if ($Context.Echo) {
        $label = '[' + $Context.TargetName + ']'
        if ($TaskId) { $label += '[' + $TaskId + ']' }
        Write-Host ("{0} {1} {2} {3}" -f ([DateTime]::Now.ToString('HH:mm:ss')), $label, $Type, $safeMessage)
    }
}
function Get-PASFileSetDigest {
    param([string[]]$Files)
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $contents = New-Object System.Text.StringBuilder
        foreach ($file in $Files) {
            if (-not [string]::IsNullOrWhiteSpace($file)) {
                [void]$contents.Append($file)
                [void]$contents.Append(':')
                [void]$contents.Append((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash)
                [void]$contents.Append(';')
            }
        }
        $data = [Text.Encoding]::UTF8.GetBytes($contents.ToString())
        return ([BitConverter]::ToString($hash.ComputeHash($data))).Replace('-', '').ToLowerInvariant()
    } finally { $hash.Dispose() }
}
function Get-PASSecretPlaintext {
    param($Secret)
    if ($Secret -is [Security.SecureString]) {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
    if ($Secret -is [pscredential]) { throw 'Use a PSCredential only for transport authentication, not task input' }
    return [string]$Secret
}
function Resolve-PASValue {
    param($Value, [hashtable]$Inventory, [hashtable]$Secrets, [hashtable]$Outputs, [hashtable]$Runtime = @{})
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Contains('SecretRef')) {
            $key = [string]$Value['SecretRef']
            if (-not $Secrets.ContainsKey($key)) { throw "Missing secret reference '$key'" }
            return (Get-PASSecretPlaintext $Secrets[$key])
        }
        if ($Value.Contains('ConfigRef')) {
            $parts = ([string]$Value['ConfigRef']).Split('.')
            $v = $Inventory
            foreach ($p in $parts) {
                if ($v -isnot [System.Collections.IDictionary] -or
                    -not $v.Contains($p)) { throw "Unknown configuration reference '$($Value['ConfigRef'])'" }
                $v = $v[$p]
            }
            return , $v
        }
        if ($Value.Contains('OutputRef')) {
            $key = [string]$Value['OutputRef']
            if (-not $Outputs.ContainsKey($key)) { throw "Missing output reference '$key'" }
            return , $Outputs[$key]
        }
        if ($Value.Contains('RuntimeRef')) {
            $key = [string]$Value['RuntimeRef']
            if (-not $Runtime.ContainsKey($key)) { throw "Unknown runtime reference '$key' (supported: $(@($Runtime.Keys) -join ', '))" }
            return $Runtime[$key]
        }
        $h = @{}
        foreach ($k in @($Value.Keys)) { $h[$k] = Resolve-PASValue $Value[$k] $Inventory $Secrets $Outputs $Runtime }
        return , $h
    }
    if ($Value -is [array]) {
        $values = @()
        foreach ($v in $Value) { $values += , (Resolve-PASValue $v $Inventory $Secrets $Outputs $Runtime) }
        return , $values
    }
    return $Value
}
function Get-PASFileLock {
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }
    try {
        return (New-Object IO.FileStream($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None))
    } catch [System.IO.IOException] {
        throw "PAExecLocked: another controller process holds the run lock '$Path'"
    }
}
function Limit-PASText {
    param([string]$Text, [int]$MaxCharacters = 20000)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -le $MaxCharacters) { return $Text }
    return $Text.Substring(0, $MaxCharacters) + ' [TRUNCATED]'
}
function ConvertTo-PASSingleQuoted {
    param([string]$Value)
    return ("'" + $Value.Replace("'", "''") + "'")
}

# Persist only typed nonsecret diagnostic outputs. Never journal arbitrary vendor-returned objects.
function Select-PASSafeData {
    param($Data, [string[]]$Redactions = @())
    $data = ConvertTo-PASHashtable $Data
    if ($data -isnot [System.Collections.IDictionary]) { throw 'Step returned unsupported Data payload' }
    $allow = @('Pacli', 'SafeName', 'Cycle', 'Metadata', 'RebootRequired', 'Computer', 'OS', 'Build', 'Hash', 'TrustBundleSHA256', 'Version', 'File')
    $out = @{}
    foreach ($key in $data.Keys) {
        $name = [string]$key
        if ($allow -cnotcontains $name) { throw "Data field '$name' is not allowed in persisted task journal" }
        $value = $data[$key]
        if ($null -eq $value) { continue }
        if ($name -in @('Hash', 'TrustBundleSHA256') -and
            ($value -isnot [string] -or
            $value -notmatch '^[A-Fa-f0-9]{64}$')) { throw "Data field $name requires a SHA256 hex digest" }
        if ($value -is [string]) {
            foreach ($secret in $Redactions) { if ($secret -and $value.Contains($secret)) { throw "Sensitive Data value rejected for $name" } }
            if ($value.Length -gt 256 -or $value -match '(?i)password|secret|bearer\s|authorization:') { throw "Unsafe Data value for $name" }
            $out[$name] = $value
        } elseif ($value -is [bool] -or $value -is [int] -or $value -is [long]) { $out[$name] = $value }
        else { throw "Data field $name must contain only a primitive value" }
    }
    return $out
}

# Remote status is untrusted. Persist a bounded evidence projection, never its arbitrary Data.
function Select-PASRemoteEvidence {
    param($Result, [string[]]$Redactions = @())
    $record = @{}
    foreach ($name in @('state', 'attemptId', 'startedUtc', 'endedUtc', 'bootUtc', 'host', 'recovery', 'message')) {
        $value = Get-PASValue $Result $name $null
        if ($null -ne $value) { $record[$name] = Limit-PASText (Protect-PASText ([string]$value) $Redactions) 2000 }
    }
    foreach ($name in @('pid', 'exitCode')) {
        $value = Get-PASValue $Result $name $null
        if ($value -is [int] -or $value -is [long]) { $record[$name] = $value }
    }
    $changed = Get-PASValue $Result 'changed' $null
    if ($changed -is [bool]) { $record.changed = $changed }
    return $record
}
function ConvertTo-PASOrderedHashtable {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        $h = [ordered]@{}
        foreach ($k in $Value.Keys) { $h[[string]$k] = ConvertTo-PASOrderedHashtable $Value[$k] }
        return $h
    }
    if ($Value -is [pscustomobject]) {
        $h = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = ConvertTo-PASOrderedHashtable $p.Value }
        return $h
    }
    if ($Value -is [System.Collections.IEnumerable]) { return , @(foreach ($i in $Value) { ConvertTo-PASOrderedHashtable $i }) }
    return $Value
}

