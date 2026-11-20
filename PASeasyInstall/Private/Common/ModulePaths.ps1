# Where the module keeps its recipe files. Only files inside this module are ever resolved.
function Get-PASModuleRoot {
    return $script:PASRoot
}

function Get-PASRecipePath {
    # Returns the full path of a recipe file given a path like 'Recipes/Vault/Workflows/VaultPrimary.psd1'.
    param([Parameter(Mandatory)][string]$RelativePath)
    $relative = $RelativePath.Replace('\', '/').TrimStart('/')
    $root = [IO.Path]::GetFullPath($script:PASRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
    if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "Recipe path leaves the module folder: $RelativePath" }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Recipe file is missing from the PASeasyInstall module: $relative" }
    return $path
}
