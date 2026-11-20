<#
.SYNOPSIS
Builds the portable PASeasyInstall ZIP: unzip, run Start-PASInstall.cmd, build a lab. No installation needed.
.DESCRIPTION
Builds the Gallery stage with Tools\Build-GalleryPackage.ps1, then lays out:
  PASeasyInstall-<version>-portable\
    Start-PASInstall.cmd / .ps1     desktop wizard
    Invoke-PASInstall.cmd / .ps1    command line install from a saved project
    PASeasyInstall-Shell.cmd / .ps1     PowerShell window with every PASeasyInstall command loaded
    README-PORTABLE.txt, LICENSE.txt, THIRD_PARTY_*.txt
    Modules\PASeasyInstall\<version>\   the module
    Modules\NativeHTMLKit.UI\, Modules\NativeHTMLKit\   desktop runtime, including its native host
The launchers unblock the extracted files, put the bundled Modules folder first on PSModulePath for
that process only, and run Windows PowerShell 5.1 with -NoProfile -ExecutionPolicy Bypass. They change
nothing on the computer, need no administrator rights to start, and work from any folder.
Writes <Output>\PASeasyInstall-<version>-portable.zip and <Output>\SHA256SUMS.
.PARAMETER NativeHTMLKitPath
Folder that already contains NativeHTMLKit.UI and NativeHTMLKit module folders (offline build).
Default: Save-Module from the PowerShell Gallery.
.EXAMPLE
.\Tools\Build-PortableRelease.ps1
.EXAMPLE
.\Tools\Build-PortableRelease.ps1 -Output C:\Temp\dist -NativeHTMLKitPath 'C:\Program Files\WindowsPowerShell\Modules'
#>
[CmdletBinding()]
param([string]$Output='',[string]$NativeHTMLKitPath='',[switch]$AllowMissingLicense)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
if(-not $Output){$Output=Join-Path $repo 'dist'}
$Output=[IO.Path]::GetFullPath($Output)
$gallery=& (Join-Path $PSScriptRoot 'Build-GalleryPackage.ps1') -Output $Output -AllowMissingLicense:$AllowMissingLicense
$data=Import-PowerShellDataFile -Path (Join-Path $gallery.Stage 'PASeasyInstall.psd1')
$moduleVersion=[string]$data.ModuleVersion
$name="PASeasyInstall-$($gallery.Version)-portable"
$portableRoot=Join-Path $Output 'portable'
$root=Join-Path $portableRoot $name
if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
$modules=Join-Path $root 'Modules'
$target=Join-Path (Join-Path $modules 'PASeasyInstall') $moduleVersion
New-Item -ItemType Directory -Path $target -Force|Out-Null
Copy-Item -Path (Join-Path $gallery.Stage '*') -Destination $target -Recurse -Force
foreach($f in @(Get-ChildItem -LiteralPath $gallery.Stage -File|Where-Object {$_.Name -like 'LICENSE*' -or $_.Name -like 'THIRD_PARTY_*'})){Copy-Item -LiteralPath $f.FullName -Destination $root -Force}

# Desktop runtime
$need=@{'NativeHTMLKit.UI'='0.1.1'}
if($NativeHTMLKitPath){
    foreach($m in @('NativeHTMLKit.UI','NativeHTMLKit')){
        $src=Join-Path $NativeHTMLKitPath $m
        if(-not(Test-Path -LiteralPath $src)){throw "$m not found in $NativeHTMLKitPath"}
        Copy-Item -LiteralPath $src -Destination $modules -Recurse -Force
    }
}else{
    Save-Module -Name NativeHTMLKit.UI -MinimumVersion $need['NativeHTMLKit.UI'] -Repository PSGallery -Path $modules -Force
}
foreach($m in @('NativeHTMLKit.UI','NativeHTMLKit')){if(-not(Test-Path -LiteralPath (Join-Path $modules $m))){throw "Portable layout is missing $m"}}
$hosts=@(Get-ChildItem -LiteralPath (Join-Path $modules 'NativeHTMLKit') -Recurse -File -Filter 'nativehtmlkit-host*')
if(-not @($hosts|Where-Object {$_.Name -eq 'nativehtmlkit-host.exe'}).Count){throw 'NativeHTMLKit native host (win-x64) is missing from the portable layout'}

# Launchers. The .ps1 files carry a BOM so Windows PowerShell 5.1 reads them as UTF-8.
$utf8Bom=New-Object Text.UTF8Encoding($true)
$ascii=New-Object Text.ASCIIEncoding
$common=@'
$ErrorActionPreference='Stop'
$PASPortableRoot=$PSScriptRoot
# Files extracted from a downloaded ZIP carry the internet zone mark; clear it inside this folder only.
Get-ChildItem -LiteralPath $PASPortableRoot -Recurse -File -ErrorAction SilentlyContinue|Unblock-File -ErrorAction SilentlyContinue
$PASPortableModules=Join-Path $PASPortableRoot 'Modules'
if(@($env:PSModulePath -split ';') -notcontains $PASPortableModules){$env:PSModulePath=$PASPortableModules+';'+$env:PSModulePath}
$PASManifest=Get-ChildItem -Path (Join-Path $PASPortableModules 'PASeasyInstall\*\PASeasyInstall.psd1')|Select-Object -First 1
if(-not $PASManifest){throw "PASeasyInstall module not found under $PASPortableModules"}
if($PSVersionTable.PSEdition -ne 'Desktop'){Write-Warning 'Installations need Windows PowerShell 5.1 (powershell.exe). This window can review plans only.'}
Import-Module $PASManifest.FullName -Force -ErrorAction Stop
'@
$startPs1=@"
<#
PASeasyInstall portable: opens the desktop wizard. Builds CyberArk PAM labs; production use is at your own risk.
Usage: Start-PASInstall.cmd [-Advanced] [-Theme v1|v2] [-Backend Mock] [-Config <project.json>]
#>
[CmdletBinding()]param([string]`$Config='',[switch]`$Advanced,[ValidateSet('v1','v2')][string]`$Theme='v2',[ValidateSet('Orchestrator','Mock')][string]`$Backend='Orchestrator')
$common
Start-PASInstall @PSBoundParameters
"@
$invokePs1=@"
<#
PASeasyInstall portable: installs, plans or resumes a lab from a saved project, from the command line.
Usage:
  Invoke-PASInstall.cmd -Config <project.json> -PlanOnly
  Invoke-PASInstall.cmd -Config <project.json> [-Wait] [-PromptLabPassword]
  Invoke-PASInstall.cmd -Resume <runId> [-RetryFailedPreflight] [-Wait]
#>
[CmdletBinding(DefaultParameterSetName='Config')]
param([Parameter(Mandatory,ParameterSetName='Config',Position=0)][string]`$Config,
    [Parameter(ParameterSetName='Config')][switch]`$PlanOnly,
    [Parameter(Mandatory,ParameterSetName='Resume')][string]`$Resume,
    [Parameter(ParameterSetName='Resume')][switch]`$RetryFailedPreflight,
    [switch]`$Wait,[int]`$PollSeconds=15,[switch]`$PromptLabPassword)
$common
`$p=@{}+`$PSBoundParameters
[void]`$p.Remove('PromptLabPassword')
if(`$PromptLabPassword){`$p.LabPassword=Read-Host -AsSecureString -Prompt 'Lab password (used for every server and secret)'}
`$result=Invoke-PASInstall @p
if(`$PlanOnly){`$result|Format-List Name,ExecutionMode,Warnings;`$result.Items|Format-Table Id,Type,Address,Os,DependsOn -AutoSize}else{`$result}
"@
$shellPs1=@"
<# PASeasyInstall portable: PowerShell window with every PASeasyInstall command loaded. #>
$common
Write-Host ('PASeasyInstall '+(Get-Module PASeasyInstall).Version+' loaded. Commands: Get-Command -Module PASeasyInstall   Help: Get-Help about_PASeasyInstall')
"@
[IO.File]::WriteAllText((Join-Path $root 'Start-PASInstall.ps1'),$startPs1,$utf8Bom)
[IO.File]::WriteAllText((Join-Path $root 'Invoke-PASInstall.ps1'),$invokePs1,$utf8Bom)
[IO.File]::WriteAllText((Join-Path $root 'PASeasyInstall-Shell.ps1'),$shellPs1,$utf8Bom)
$ps='"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"'
$cmdStart="@echo off`r`nrem PASeasyInstall portable desktop. Builds CyberArk PAM labs; production use is at your own risk.`r`nsetlocal`r`n$ps -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Start-PASeasyInstall.ps1`" %*`r`nif errorlevel 1 (`r`n  echo.`r`n  echo PASeasyInstall exited with error %errorlevel%.`r`n  pause`r`n)`r`nendlocal`r`n"
$cmdInvoke="@echo off`r`nrem PASeasyInstall portable command line. Example: Invoke-PASInstall.cmd -Config MyLab.json -PlanOnly`r`nsetlocal`r`n$ps -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Invoke-PASeasyInstall.ps1`" %*`r`nset rc=%errorlevel%`r`nendlocal & exit /b %rc%`r`n"
$cmdShell="@echo off`r`nrem PASeasyInstall portable: PowerShell window with all commands loaded.`r`n$ps -NoExit -NoProfile -ExecutionPolicy Bypass -File `"%~dp0PASeasyInstall-Shell.ps1`"`r`n"
[IO.File]::WriteAllText((Join-Path $root 'Start-PASInstall.cmd'),$cmdStart,$ascii)
[IO.File]::WriteAllText((Join-Path $root 'Invoke-PASInstall.cmd'),$cmdInvoke,$ascii)
[IO.File]::WriteAllText((Join-Path $root 'PASeasyInstall-Shell.cmd'),$cmdShell,$ascii)
$uiVersion=(Get-ChildItem -LiteralPath (Join-Path $modules 'NativeHTMLKit.UI') -Directory|Select-Object -First 1).Name
$hkVersion=(Get-ChildItem -LiteralPath (Join-Path $modules 'NativeHTMLKit') -Directory|Select-Object -First 1).Name
$readme=@"
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
3. Double-click Start-PASInstall.cmd. The six-step wizard opens. Nothing is sent to a server until you
   press Install on the last step.

   Start-PASInstall.cmd -Backend Mock      the same window with simulated installs (demo)
   Invoke-PASInstall.cmd -Config MyLab.json -PlanOnly
   Invoke-PASInstall.cmd -Config MyLab.json -Wait
   PASeasyInstall-Shell.cmd                    PowerShell window with every command loaded

Requirements
------------
- This computer (the controller): Windows with Windows PowerShell 5.1, for example Windows Server 2022 or
  Windows 10/11. Installations run from Windows PowerShell 5.1.
- Target servers: Windows Server 2022 for Vault, DR, PVWA, CPM, PSM and AD; Ubuntu 24.04 or RHEL 8/9 for
  PSMP. WinRM over HTTPS (5986) for Windows targets, SSH for Linux targets.
- CyberArk PAM self-hosted installation media, a license file and the public recovery key.

What the launchers do
---------------------
They clear the "downloaded from the internet" mark inside this folder, put this folder's Modules first on
PSModulePath for their own process, and start Windows PowerShell with -NoProfile -ExecutionPolicy Bypass.
Nothing is installed or changed on the computer. Execution policy enforced by Group Policy still applies.

Contents
--------
Modules\PASeasyInstall\$moduleVersion      PASeasyInstall
Modules\NativeHTMLKit.UI\$uiVersion        desktop UI library (https://nativehtmlkit.github.io/)
Modules\NativeHTMLKit\$hkVersion           NativeHTMLKit SDK and native window host

Documentation: https://github.com/bigbatmanorg/PASeasyInstall
"@
[IO.File]::WriteAllText((Join-Path $root 'README-PORTABLE.txt'),($readme -replace "`r?`n","`r`n"),$utf8Bom)

# ZIP with forward-slash entries (Windows PowerShell 5.1's CreateFromDirectory writes backslashes).
$zipPath=Join-Path $Output ($name+'.zip')
if(Test-Path -LiteralPath $zipPath){Remove-Item -LiteralPath $zipPath -Force}
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stream=[IO.File]::Open($zipPath,[IO.FileMode]::CreateNew)
try{
    $zip=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create)
    try{
        foreach($f in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force)){
            $entry=$name+'/'+($f.FullName.Substring($root.Length+1) -replace '\\','/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$f.FullName,$entry,[IO.Compression.CompressionLevel]::Optimal)
        }
    }finally{$zip.Dispose()}
}finally{$stream.Dispose()}
$hash=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$sums=Join-Path $Output 'SHA256SUMS'
[IO.File]::WriteAllText($sums,"$hash  $(Split-Path -Leaf $zipPath)`n",(New-Object Text.UTF8Encoding($false)))
[pscustomobject]@{Version=$gallery.Version;Zip=$zipPath;SizeMB=[math]::Round((Get-Item -LiteralPath $zipPath).Length/1MB,1);SHA256=$hash;Folder=$root;
    NativeHTMLKitUI=$uiVersion;NativeHTMLKit=$hkVersion;GalleryStage=$gallery.Stage}
