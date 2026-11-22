<#
.SYNOPSIS
Builds the portable PASeasyInstall ZIP: unzip, run Start-PASeasyInstall.cmd, build a lab. No installation needed.
.DESCRIPTION
Stages the module with Tools\Build-GalleryPackage.ps1, then lays out:
  PASeasyInstall-<version>-portable\
    Start-PASeasyInstall.cmd / .ps1     the desktop window
    PASeasyInstall-Shell.cmd / .ps1     PowerShell window with the PASeasyInstall commands loaded
    README-PORTABLE.txt, LICENSE.txt, THIRD_PARTY_*.txt
    PASeasyInstall\                     the module (commands and desktop window)
The launchers clear the internet zone mark inside the folder, put the folder first on PSModulePath for
their own process only, and run Windows PowerShell 5.1 with -NoProfile -ExecutionPolicy Bypass. They
change nothing on the computer, need no administrator rights to start, and work from any folder.
Writes <Output>\PASeasyInstall-<version>-portable.zip and <Output>\SHA256SUMS.
The desktop window is drawn with WPF, which is part of Windows: the package holds no runtime and the
build needs no download.
.EXAMPLE
.\Tools\Build-PortableRelease.ps1
.EXAMPLE
.\Tools\Build-PortableRelease.ps1 -Output C:\Temp\dist
#>
[CmdletBinding()]
param(
    [string]$Output = '',
    [switch]$AllowMissingLicense
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
if (-not $Output) {
    $Output = Join-Path $repo 'dist'
}
$Output = [IO.Path]::GetFullPath($Output)

$gallery = & (Join-Path $PSScriptRoot 'Build-GalleryPackage.ps1') -Output $Output -AllowMissingLicense:$AllowMissingLicense
$name = "PASeasyInstall-$($gallery.Version)-portable"
$portableRoot = Join-Path $Output 'portable'
$root = Join-Path $portableRoot $name
if (Test-Path -LiteralPath $root) {
    Remove-Item -LiteralPath $root -Recurse -Force
}
New-Item -ItemType Directory -Path $root -Force | Out-Null

# 1. The module, in a folder with its name
foreach ($package in @($gallery.Packages)) {
    $target = Join-Path $root $package.Module
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $package.Stage '*') -Destination $target -Recurse -Force
}
$coreStage = Join-Path $root 'PASeasyInstall'
foreach ($file in @(Get-ChildItem -LiteralPath $coreStage -File | Where-Object { $_.Name -like 'LICENSE*' -or $_.Name -like 'THIRD_PARTY_*' })) {
    Copy-Item -LiteralPath $file.FullName -Destination $root -Force
}

# 2. Launchers. The .ps1 files carry a BOM so Windows PowerShell 5.1 reads them as UTF-8.
$utf8Bom = New-Object Text.UTF8Encoding($true)
$ascii = New-Object Text.ASCIIEncoding
$common = @'
$ErrorActionPreference = 'Stop'
$PASPortableRoot = $PSScriptRoot
# Files extracted from a downloaded ZIP carry the internet zone mark; clear it inside this folder only.
Get-ChildItem -LiteralPath $PASPortableRoot -Recurse -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
# The module folders of this package come first, for this process only.
if (@($env:PSModulePath -split ';') -notcontains $PASPortableRoot) {
    $env:PSModulePath = $PASPortableRoot + ';' + $env:PSModulePath
}
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    Write-Warning 'Installations need Windows PowerShell 5.1 (powershell.exe). This window can review plans only.'
}
'@
$startPs1 = @"
<#
PASeasyInstall portable: opens the desktop window. Builds CyberArk PAM labs; production use is at your own risk.
Usage: Start-PASeasyInstall.cmd [-Config <project.json>] [-Backend Mock]
#>
[CmdletBinding()]
param(
    [string]`$Config = '',
    [ValidateSet('Live', 'Mock')][string]`$Backend = 'Live'
)
$common
Import-Module (Join-Path (Join-Path `$PASPortableRoot 'PASeasyInstall') 'PASeasyInstall.psd1') -Force -ErrorAction Stop
Start-PASeasyInstall -Config `$Config -Backend `$Backend
"@
$shellPs1 = @"
<# PASeasyInstall portable: PowerShell window with the PASeasyInstall commands loaded. #>
$common
Import-Module (Join-Path (Join-Path `$PASPortableRoot 'PASeasyInstall') 'PASeasyInstall.psd1') -Force -ErrorAction Stop
Write-Host ('PASeasyInstall ' + (Get-Module PASeasyInstall).Version + ' loaded. Commands: Get-Command -Module PASeasyInstall   Help: Get-Help about_PASeasyInstall')
"@
[IO.File]::WriteAllText((Join-Path $root 'Start-PASeasyInstall.ps1'), $startPs1, $utf8Bom)
[IO.File]::WriteAllText((Join-Path $root 'PASeasyInstall-Shell.ps1'), $shellPs1, $utf8Bom)
$ps = '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"'
$cmdStart = "@echo off`r`nrem PASeasyInstall portable desktop. Builds CyberArk PAM labs; production use is at your own risk.`r`nsetlocal`r`n$ps -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Start-PASeasyInstall.ps1`" %*`r`nif errorlevel 1 (`r`n  echo.`r`n  echo PASeasyInstall exited with error %errorlevel%.`r`n  pause`r`n)`r`nendlocal`r`n"
$cmdShell = "@echo off`r`nrem PASeasyInstall portable: PowerShell window with the commands loaded.`r`n$ps -NoExit -NoProfile -ExecutionPolicy Bypass -File `"%~dp0PASeasyInstall-Shell.ps1`"`r`n"
[IO.File]::WriteAllText((Join-Path $root 'Start-PASeasyInstall.cmd'), $cmdStart, $ascii)
[IO.File]::WriteAllText((Join-Path $root 'PASeasyInstall-Shell.cmd'), $cmdShell, $ascii)

# 3. README
$readme = @"
PASeasyInstall $($gallery.Version) - portable edition
====================================================

Builds CyberArk PAM self-hosted LABS from this computer: Primary Vault (optionally with DR), PVWA, CPM,
PSM, PSMP and an Active Directory lab forest. Intended for labs, demos and training. Production use is
at your own risk. You supply the CyberArk installation media and license. Not affiliated with CyberArk.

Start
-----
1. Before extracting, right-click the ZIP > Properties > Unblock (or: Unblock-File <zip>). This avoids
   Windows security prompts for the extracted launchers.
2. Extract anywhere, for example C:\PASeasyInstall or a USB drive.
3. Double-click Start-PASeasyInstall.cmd. The window opens. Nothing is sent to a server until
   you press Install on the last step.

   Start-PASeasyInstall.cmd -Backend Mock          the same window with a simulated installation (demo)
   Start-PASeasyInstall.cmd -Config MyLab.json     reopen a saved project
   PASeasyInstall-Shell.cmd                        PowerShell window with the commands loaded, e.g.
                                                   Install-PASVault, Install-PASLab, Get-PASRun

Requirements
------------
- This computer (the controller): Windows with Windows PowerShell 5.1, for example Windows Server 2022 or
  Windows 10/11. Installations run from Windows PowerShell 5.1.
- Target servers: Windows Server 2022 for Vault, DR, PVWA, CPM, PSM and AD; Ubuntu 22.04/24.04 or
  RHEL-family 8/9 for PSMP. WinRM over HTTPS (5986) for Windows targets, SSH for Linux targets.
- CyberArk PAM self-hosted installation media, a license file and the public recovery key.

What the launchers do
---------------------
They clear the "downloaded from the internet" mark inside this folder, put this folder first on
PSModulePath for their own process, and start Windows PowerShell with -NoProfile -ExecutionPolicy Bypass.
Nothing is installed or changed on the computer. Execution policy enforced by Group Policy still applies.

Contents
--------
PASeasyInstall\                       the module: the commands and the desktop window (Start-PASeasyInstall)
The window is drawn with WPF, which is part of Windows. No other runtime is needed or included.

Documentation: https://bigbatmanorg.github.io/PASeasyInstall/
"@
[IO.File]::WriteAllText((Join-Path $root 'README-PORTABLE.txt'), ($readme -replace "`r?`n", "`r`n"), $utf8Bom)

# 4. ZIP with forward-slash entries (Windows PowerShell 5.1's CreateFromDirectory writes backslashes).
$zipPath = Join-Path $Output ($name + '.zip')
if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
try {
    $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)) {
            $entry = $name + '/' + ($file.FullName.Substring($root.Length + 1) -replace '\\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $entry, [IO.Compression.CompressionLevel]::Optimal)
        }
    } finally {
        $zip.Dispose()
    }
} finally {
    $stream.Dispose()
}
$hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$sums = Join-Path $Output 'SHA256SUMS'
[IO.File]::WriteAllText($sums, "$hash  $(Split-Path -Leaf $zipPath)`n", (New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{
    Version = $gallery.Version
    Zip = $zipPath
    SizeMB = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
    SHA256 = $hash
    Folder = $root
    GalleryRoot = $gallery.GalleryRoot
}
