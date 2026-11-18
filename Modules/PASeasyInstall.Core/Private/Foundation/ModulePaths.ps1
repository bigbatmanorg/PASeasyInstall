# Local module tree resolver. Never discover arbitrary plugin code from operator paths.
function Get-PASModulesRoot { return (Split-Path -Parent $script:PASRoot) }
function Get-PASModuleRoot {
    param([Parameter(Mandatory)][ValidateSet('Core','Vault','DR','PVWA','CPM','PSM','PSMP','PTA','AD','Orchestrator','UI')][string]$Name)
    $path=Join-Path (Get-PASModulesRoot) ('PASeasyInstall.'+$Name)
    if(-not(Test-Path -LiteralPath $path -PathType Container)){throw "Required PASeasyInstall module is missing: $Name"}
    return $path
}
function Get-PASRecipePath {
    # Private, reviewed asset paths only. Normalized and bounded to this source package.
    param([Parameter(Mandatory)][string]$RelativePath)
    $relative=$RelativePath.Replace('\','/').TrimStart('/')
    $module='Core'
    if($relative.StartsWith('Recipes/Vault/',[StringComparison]::Ordinal)){$module='Vault'}
    elseif($relative.StartsWith('Recipes/ActiveDirectory/',[StringComparison]::Ordinal)){$module='AD'}
    elseif($relative -in @('Recipes/WindowsComponent/PvwaTls.ps1','Recipes/WindowsComponent/CpmTls.ps1','Recipes/WindowsComponent/Psm.ps1')){
        $module=switch(($relative -split '/')[-1]){'PvwaTls.ps1'{'PVWA'}'CpmTls.ps1'{'CPM'}'Psm.ps1'{'PSM'}}
    }
    $root=Get-PASModuleRoot $module
    $path=[IO.Path]::GetFullPath((Join-Path $root $relative))
    $prefix=[IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {throw 'Recipe path escapes owned module'}
    if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw "Missing recipe asset in PASeasyInstall.$($module): $relative"}
    return $path
}
