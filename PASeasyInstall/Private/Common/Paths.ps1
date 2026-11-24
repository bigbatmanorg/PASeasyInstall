function Get-PASDataRoot {
    [CmdletBinding()] param()
    if ($env:PAS_EASY_DATA_ROOT) { return [IO.Path]::GetFullPath($env:PAS_EASY_DATA_ROOT) }
    if ($env:OS -eq 'Windows_NT') { return (Join-Path $env:LOCALAPPDATA 'PASeasyInstall') }
    return (Join-Path $HOME '.local/share/PASeasyInstall')
}

function Write-PASJsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Data)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = Join-Path $dir ('.pas-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $json = $Data | ConvertTo-Json -Depth 60
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    try {
        # [NullString]::Value, not $null: Windows PowerShell 5.1 passes $null to a .NET string parameter as ''
        # and File.Replace then rejects the empty backup path ("The path is not of a legal form").
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }
        else {
            try { [IO.File]::Move($tmp, $Path) }
            catch [System.IO.IOException] {
                # Another writer created the file between the test and the move (two checks of the same media
                # at once): replace it instead ("Cannot create a file when that file already exists").
                if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw }
                [IO.File]::Replace($tmp, $Path, [NullString]::Value)
            }
        }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}

function Read-PASJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Get-PASValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $Default
}
