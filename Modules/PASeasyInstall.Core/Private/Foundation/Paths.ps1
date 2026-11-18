function Get-PASDataRoot {
    [CmdletBinding()] param()
    if ($env:PAS_EASY_DATA_ROOT) { return [IO.Path]::GetFullPath($env:PAS_EASY_DATA_ROOT) }
    if ($env:OS -eq 'Windows_NT') { return (Join-Path $env:LOCALAPPDATA 'PASeasyInstall') }
    return (Join-Path $HOME '.local/share/PASeasyInstall')
}

function Get-PASSourcesStatus {
    [CmdletBinding()] param()
    $p = Join-Path $script:PASRoot 'Private/Engine/Engine.ps1'
    $v = Get-PASRecipePath 'Recipes/Vault/Workflows/VaultPrimaryOnly.psd1'
    $b = Get-PASRecipePath 'Recipes/Vault/Workflows/VaultDR.psd1'
    $ok = ((Test-Path -LiteralPath $p -PathType Leaf) -and (Test-Path -LiteralPath $v -PathType Leaf) -and (Test-Path -LiteralPath $b -PathType Leaf))
    return [pscustomobject]@{ Ready=$ok; PAExec=$p; Primary=$v; DR=$b;
        Message=$(if($ok){'Bundled installation source files are present; qualification is separate'}else{'Bundled source files are missing; reinstall the PASeasyInstall package'}) }
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
        else { [IO.File]::Move($tmp, $Path) }
    } finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}

function Read-PASJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { return $null }
}

function Get-PASProp {
    param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $p=$Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $Default
}
