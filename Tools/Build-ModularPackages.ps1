<#
.SYNOPSIS
Copy every stand-alone PowerShell module into a conventional module root.
.DESCRIPTION
Static source package staging. No Gallery publishing, vendors, or remote mutations.
Each component has a dedicated manifest and can be imported without the UI.
#>
[CmdletBinding(SupportsShouldProcess=$true)]param([string]$Output=(Join-Path $PSScriptRoot '..\dist\Modules'))
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$source=Join-Path $root 'Modules'
$dest=[IO.Path]::GetFullPath($Output)
if((Test-Path -LiteralPath $dest) -and @((Get-ChildItem -LiteralPath $dest -Force)).Count){throw 'Output directory is not empty; use a fresh path.'}
if($PSCmdlet.ShouldProcess($dest,'Stage independent module directories')){
    $null=New-Item -ItemType Directory -Path $dest -Force
    foreach($module in @(Get-ChildItem -LiteralPath $source -Directory | Sort-Object Name)){
        $manifest=Join-Path $module.FullName ($module.Name+'.psd1')
        if(-not(Test-Path -LiteralPath $manifest)){throw ('Manifest missing: '+$manifest)}
        Test-ModuleManifest -Path $manifest -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $module.FullName -Destination $dest -Recurse -Force
        Write-Output (Join-Path $dest $module.Name)
    }
}
