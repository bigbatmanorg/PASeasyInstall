<#
.SYNOPSIS
Stages the PASeasyInstall PowerShell Gallery package and checks it before publishing.
.DESCRIPTION
Copies the umbrella module (PASeasyInstall.psd1/.psm1, en-US help), every Modules\PASeasyInstall.* module,
LICENSE and the third-party license files into <Output>\gallery\PASeasyInstall. Tests, tools, docs,
screenshots, lab files and UI test helpers are left out.
It then:
  - refuses vendor media, binaries, keys and licence files, and content that looks like a private key,
    the lab password, a lab address or a lab host name;
  - writes a file inventory with SHA256 hashes and runs Test-ModuleManifest;
  - with -LocalRepositoryPath, publishes the package to a local folder repository to test Install-Module.
    -MirrorDependencies also copies NativeHTMLKit.UI and NativeHTMLKit there from the PowerShell Gallery.
It never publishes to the PowerShell Gallery; .github/workflows/release.yml does that.
.EXAMPLE
.\Tools\Build-GalleryPackage.ps1
.EXAMPLE
.\Tools\Build-GalleryPackage.ps1 -Output C:\Temp\pkg -LocalRepositoryPath C:\Temp\repo -MirrorDependencies
#>
[CmdletBinding()]
param([string]$Output='',[string]$LocalRepositoryPath='',[string]$LocalRepositoryName='PASeasyLocal',
    [switch]$MirrorDependencies,[switch]$AllowMissingLicense)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$repo=(Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
if(-not $Output){$Output=Join-Path $repo 'dist'}
$Output=[IO.Path]::GetFullPath($Output)
$manifestPath=Join-Path $repo 'PASeasyInstall.psd1'
$data=Import-PowerShellDataFile -Path $manifestPath
$pre=[string]$data.PrivateData.PSData.Prerelease
$version=[string]$data.ModuleVersion+$(if($pre){'-'+$pre}else{''})
$galleryRoot=Join-Path $Output 'gallery'
$stage=Join-Path $galleryRoot 'PASeasyInstall'
if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
New-Item -ItemType Directory -Path $stage -Force|Out-Null

function Copy-PASItem([string]$From,[string]$To){
    New-Item -ItemType Directory -Path (Split-Path -Parent $To) -Force|Out-Null
    Copy-Item -LiteralPath $From -Destination $To -Force
}
# 1. Umbrella module, help and licenses
foreach($f in @('PASeasyInstall.psd1','PASeasyInstall.psm1')){Copy-PASItem (Join-Path $repo $f) (Join-Path $stage $f)}
foreach($f in @(Get-ChildItem -LiteralPath (Join-Path $repo 'en-US') -File)){Copy-PASItem $f.FullName (Join-Path (Join-Path $stage 'en-US') $f.Name)}
$license=Join-Path $repo 'LICENSE'
if(Test-Path -LiteralPath $license -PathType Leaf){Copy-PASItem $license (Join-Path $stage 'LICENSE.txt')}
elseif(-not $AllowMissingLicense){throw 'LICENSE is missing at the repository root (use -AllowMissingLicense only for local tests)'}
foreach($f in @(Get-ChildItem -LiteralPath (Join-Path $repo 'Docs') -Filter 'THIRD_PARTY_*.txt' -File)){Copy-PASItem $f.FullName (Join-Path $stage $f.Name)}
# 2. Engine, recipes, orchestrator and UI (PTA stays in the package for future tests; it is not exported)
$excludeDirs=@('PASeasyInstall.UI\Legacy')
foreach($f in @(Get-ChildItem -LiteralPath (Join-Path $repo 'Modules') -Recurse -File -Force)){
    $rel=$f.FullName.Substring($repo.Length+1)
    $inner=$rel.Substring('Modules\'.Length) -replace '/','\'
    if(@($excludeDirs|Where-Object {$inner.StartsWith($_+'\')}).Count){continue}
    if($f.Name -like '*.Tests.ps1' -or $f.Name -like '.*'){continue}
    Copy-PASItem $f.FullName (Join-Path $stage $rel)
}

# 3. Forbidden content
$problems=New-Object System.Collections.ArrayList
$forbiddenExt=@('.zip','.exe','.msi','.dll','.key','.pvk','.pfx','.p12','.cer','.crt','.pem','.lic','.nupkg')
$labPassword=-join [char[]](67,121,98,101,114,97,114,107,48,49,33)
$textExt=@('.ps1','.psm1','.psd1','.json','.css','.txt','.md','.sh','.xml','.j2','.ini','.iss','.html')
$patterns=@(
    @{N='private key';R='-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----'},
    @{N='lab address';R='\b10\.0\.1[12]0\.\d'},
    @{N='lab host name';R='(?i)\b(win[d]ev|pve[y]|pve[z])\b'},
    @{N='API key or token';R='\boy2[a-z0-9]{40,}\b|\bgh[opsu]_[A-Za-z0-9]{30,}\b'}
)
foreach($f in @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force)){
    $rel=$f.FullName.Substring($stage.Length+1)
    if($f.Extension.ToLowerInvariant() -in $forbiddenExt){[void]$problems.Add("$rel : forbidden file type");continue}
    if($f.Name -ieq 'license.xml'){[void]$problems.Add("$rel : vendor license file");continue}
    if($f.Extension.ToLowerInvariant() -notin $textExt){[void]$problems.Add("$rel : unexpected file type (add it to the build allow-list if intended)");continue}
    $text=[IO.File]::ReadAllText($f.FullName)
    if($text.Contains($labPassword)){[void]$problems.Add("$rel : lab password")}
    foreach($p in $patterns){if($text -match $p.R){[void]$problems.Add("$rel : $($p.N)")}}
}
if($problems.Count){throw ("Package content check failed:`n  "+(@($problems) -join "`n  "))}

# 4. Inventory and manifest test
$files=@(Get-ChildItem -LiteralPath $stage -Recurse -File -Force|Sort-Object FullName|ForEach-Object {
    [pscustomobject]@{Path=($_.FullName.Substring($stage.Length+1) -replace '\\','/');Length=$_.Length;SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
$inventory=[ordered]@{schemaVersion=1;module='PASeasyInstall';version=$version;builtUtc=[DateTime]::UtcNow.ToString('o');fileCount=$files.Count;files=$files}
$inventoryPath=Join-Path $galleryRoot 'PASeasyInstall.inventory.json'
[IO.File]::WriteAllText($inventoryPath,($inventory|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
$tested=Test-ModuleManifest -Path (Join-Path $stage 'PASeasyInstall.psd1') -ErrorAction Stop
if([string]$tested.Version -ne [string]$data.ModuleVersion){throw 'Staged manifest version mismatch'}

# 5. Optional local repository (Install-Module test without the PowerShell Gallery)
$published=$false
if($LocalRepositoryPath){
    $LocalRepositoryPath=[IO.Path]::GetFullPath($LocalRepositoryPath)
    New-Item -ItemType Directory -Path $LocalRepositoryPath -Force|Out-Null
    if(-not(Get-Command Publish-PSResource -ErrorAction SilentlyContinue)){
        throw 'Publishing to a local repository needs Microsoft.PowerShell.PSResourceGet (Install-Module Microsoft.PowerShell.PSResourceGet -Scope CurrentUser, or import a saved copy)'
    }
    if(-not(Get-PSResourceRepository -Name $LocalRepositoryName -ErrorAction SilentlyContinue)){
        Register-PSResourceRepository -Name $LocalRepositoryName -Uri $LocalRepositoryPath -Trusted
    }
    Publish-PSResource -Path $stage -Repository $LocalRepositoryName -SkipDependenciesCheck
    if($MirrorDependencies){
        Save-PSResource -Name NativeHTMLKit.UI -Repository PSGallery -AsNupkg -Path $LocalRepositoryPath -TrustRepository
    }
    $published=$true
}
[pscustomobject]@{Module='PASeasyInstall';Version=$version;Stage=$stage;Files=$files.Count;
    SizeKB=[math]::Round((($files|Measure-Object Length -Sum).Sum)/1KB);Inventory=$inventoryPath;LocalRepository=$(if($published){$LocalRepositoryPath}else{''})}
