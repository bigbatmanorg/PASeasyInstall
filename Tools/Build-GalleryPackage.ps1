<#
.SYNOPSIS
Stages the two PowerShell Gallery packages (PASeasyInstall and PASeasyInstall.UI) and checks them.
.DESCRIPTION
Copies each module folder of the repository into <Output>\gallery\<module name>:
  PASeasyInstall       the core module (commands, recipes, help, license files); no dependencies
  PASeasyInstall.UI    the desktop window; requires NativeHTMLKit
Tests, tools, docs and screenshots are not part of a package.
For both packages it then:
  - refuses vendor media, binaries, keys and license files, and content that looks like a private key,
    the lab password, a lab address or a lab host name;
  - writes a file inventory with SHA256 hashes (<Output>\gallery\<module name>.inventory.json);
  - checks the manifest, and that both manifests carry the same version.
With -LocalRepositoryPath both packages are published to a local folder repository (core first), to
test Install-Module without the PowerShell Gallery. -MirrorDependencies also copies NativeHTMLKit
there. This script never publishes to the PowerShell Gallery; .github/workflows/release.yml does that.
.OUTPUTS
Version, GalleryRoot, Packages (Module, Stage, Files, SizeKB, Inventory), LocalRepository.
.EXAMPLE
.\Tools\Build-GalleryPackage.ps1
.EXAMPLE
.\Tools\Build-GalleryPackage.ps1 -Output C:\Temp\pkg -LocalRepositoryPath C:\Temp\repo -MirrorDependencies
#>
[CmdletBinding()]
param(
    [string]$Output = '',
    [string]$LocalRepositoryPath = '',
    [string]$LocalRepositoryName = 'PASeasyLocal',
    [switch]$MirrorDependencies,
    [switch]$AllowMissingLicense
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).ProviderPath
if (-not $Output) {
    $Output = Join-Path $repo 'dist'
}
$Output = [IO.Path]::GetFullPath($Output)
$galleryRoot = Join-Path $Output 'gallery'
# Core first: the UI package depends on it at run time, and publishing follows this order.
$moduleNames = @('PASeasyInstall', 'PASeasyInstall.UI')
$nativeKitVersion = '0.1.2'

function Get-PackageVersion {
    # ModuleVersion plus the optional PSData.Prerelease label, for example 2.0.0 or 2.0.0-rc1.
    param([string]$ManifestPath)
    $data = Import-PowerShellDataFile -Path $ManifestPath
    $version = [string]$data.ModuleVersion
    $private = $data['PrivateData']
    if ($private -and $private['PSData'] -and $private['PSData']['Prerelease']) {
        $version = $version + '-' + [string]$private['PSData']['Prerelease']
    }
    return $version
}

function Copy-PackageFile {
    param([string]$From, [string]$To)
    New-Item -ItemType Directory -Path (Split-Path -Parent $To) -Force | Out-Null
    Copy-Item -LiteralPath $From -Destination $To -Force
}

function Get-PackageProblems {
    # Everything in a staged package that must not be published. Returns one line per problem.
    param([string]$Stage)
    $problems = New-Object System.Collections.ArrayList
    $forbiddenExtensions = @('.zip', '.exe', '.msi', '.dll', '.key', '.pvk', '.pfx', '.p12', '.cer', '.crt', '.pem', '.lic', '.nupkg')
    $textExtensions = @('.ps1', '.psm1', '.psd1', '.json', '.css', '.txt', '.md', '.sh', '.xml', '.j2', '.ini', '.iss', '.html')
    # Written as character codes so that this script does not contain the value it searches for.
    $labPassword = -join [char[]](67, 121, 98, 101, 114, 97, 114, 107, 48, 49, 33)
    $patterns = @(
        @{ Name = 'private key'; Regex = '-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----' },
        @{ Name = 'lab address'; Regex = '\b10\.0\.1[12]0\.\d' },
        @{ Name = 'lab host name'; Regex = '(?i)\b(win[d]ev|pve[y]|pve[z])\b' },
        @{ Name = 'API key or token'; Regex = '\boy2[a-z0-9]{40,}\b|\bgh[opsu]_[A-Za-z0-9]{30,}\b' }
    )
    foreach ($file in @(Get-ChildItem -LiteralPath $Stage -Recurse -File -Force)) {
        $relative = $file.FullName.Substring($Stage.Length + 1)
        $extension = $file.Extension.ToLowerInvariant()
        if ($extension -in $forbiddenExtensions) {
            [void]$problems.Add("$relative : forbidden file type")
            continue
        }
        if ($file.Name -ieq 'license.xml') {
            [void]$problems.Add("$relative : vendor license file")
            continue
        }
        if ($extension -notin $textExtensions) {
            [void]$problems.Add("$relative : unexpected file type (add it to the build allow-list if intended)")
            continue
        }
        $text = [IO.File]::ReadAllText($file.FullName)
        if ($text.Contains($labPassword)) {
            [void]$problems.Add("$relative : lab password")
        }
        foreach ($pattern in $patterns) {
            if ($text -match $pattern.Regex) {
                [void]$problems.Add("$relative : $($pattern.Name)")
            }
        }
    }
    return @($problems)
}

$license = Join-Path $repo 'LICENSE'
$version = Get-PackageVersion (Join-Path (Join-Path $repo 'PASeasyInstall') 'PASeasyInstall.psd1')
$packages = @()
foreach ($name in $moduleNames) {
    $source = Join-Path $repo $name
    $sourceManifest = Join-Path $source ($name + '.psd1')
    if (-not (Test-Path -LiteralPath $sourceManifest -PathType Leaf)) {
        throw "Module manifest not found: $sourceManifest"
    }
    if ((Get-PackageVersion $sourceManifest) -ne $version) {
        throw "$name has version $(Get-PackageVersion $sourceManifest), but PASeasyInstall has $version. Both manifests must carry the same version."
    }
    $stage = Join-Path $galleryRoot $name
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    # 1. Module files
    foreach ($file in @(Get-ChildItem -LiteralPath $source -Recurse -File -Force)) {
        if ($file.Name -like '*.Tests.ps1' -or $file.Name -like '.*') {
            continue
        }
        $relative = $file.FullName.Substring($source.Length + 1)
        Copy-PackageFile $file.FullName (Join-Path $stage $relative)
    }

    # 2. License: the module folder's own LICENSE.txt, otherwise the LICENSE of the repository.
    $stagedLicense = Join-Path $stage 'LICENSE.txt'
    if (-not (Test-Path -LiteralPath $stagedLicense -PathType Leaf)) {
        if (Test-Path -LiteralPath $license -PathType Leaf) {
            Copy-PackageFile $license $stagedLicense
        } elseif (-not $AllowMissingLicense) {
            throw 'LICENSE is missing at the repository root (use -AllowMissingLicense only for local tests)'
        }
    }

    # 3. Forbidden content
    $problems = @(Get-PackageProblems $stage)
    if ($problems.Count) {
        throw ("Package content check failed for ${name}:`n  " + ($problems -join "`n  "))
    }

    # 4. Inventory
    $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
            [pscustomobject]@{
                Path = ($_.FullName.Substring($stage.Length + 1) -replace '\\', '/')
                Length = $_.Length
                SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        })
    $inventory = [ordered]@{
        schemaVersion = 1
        module = $name
        version = $version
        builtUtc = [DateTime]::UtcNow.ToString('o')
        fileCount = $files.Count
        files = $files
    }
    $inventoryPath = Join-Path $galleryRoot ($name + '.inventory.json')
    [IO.File]::WriteAllText($inventoryPath, ($inventory | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

    # 5. Manifest. Test-ModuleManifest needs the required modules to be installed; the UI package
    #    requires NativeHTMLKit, so without it only the manifest data is checked.
    $stagedManifest = Join-Path $stage ($name + '.psd1')
    $stagedData = Import-PowerShellDataFile -Path $stagedManifest
    $canTest = $true
    if ($name -eq 'PASeasyInstall.UI' -and -not (Get-Module -ListAvailable -Name NativeHTMLKit)) {
        $canTest = $false
        Write-Warning 'NativeHTMLKit is not installed: the PASeasyInstall.UI manifest was read but not tested with Test-ModuleManifest.'
    }
    if ($canTest) {
        $tested = Test-ModuleManifest -Path $stagedManifest -ErrorAction Stop
        if ([string]$tested.Version -ne [string]$stagedData.ModuleVersion) {
            throw "Staged manifest version mismatch for $name"
        }
    }
    if ($name -eq 'PASeasyInstall' -and $stagedData.ContainsKey('RequiredModules') -and @($stagedData.RequiredModules).Count) {
        throw 'The core module must not require other modules'
    }

    $size = ($files | Measure-Object -Property Length -Sum).Sum
    $packages += [pscustomobject]@{
        Module = $name
        Stage = $stage
        Files = $files.Count
        SizeKB = [math]::Round($size / 1KB)
        Inventory = $inventoryPath
    }
}

# 6. Optional local repository (Install-Module test without the PowerShell Gallery)
$published = $false
if ($LocalRepositoryPath) {
    $LocalRepositoryPath = [IO.Path]::GetFullPath($LocalRepositoryPath)
    New-Item -ItemType Directory -Path $LocalRepositoryPath -Force | Out-Null
    if (-not (Get-Command Publish-PSResource -ErrorAction SilentlyContinue)) {
        throw 'Publishing to a local repository needs Microsoft.PowerShell.PSResourceGet (Install-Module Microsoft.PowerShell.PSResourceGet -Scope CurrentUser, or import a saved copy)'
    }
    if (-not (Get-PSResourceRepository -Name $LocalRepositoryName -ErrorAction SilentlyContinue)) {
        Register-PSResourceRepository -Name $LocalRepositoryName -Uri $LocalRepositoryPath -Trusted
    }
    foreach ($package in $packages) {
        Publish-PSResource -Path $package.Stage -Repository $LocalRepositoryName -SkipDependenciesCheck
    }
    if ($MirrorDependencies) {
        Save-PSResource -Name NativeHTMLKit -Version $nativeKitVersion -Repository PSGallery -AsNupkg -Path $LocalRepositoryPath -TrustRepository
    }
    $published = $true
}

$localRepository = ''
if ($published) {
    $localRepository = $LocalRepositoryPath
}
[pscustomobject]@{
    Version = $version
    GalleryRoot = $galleryRoot
    Packages = $packages
    LocalRepository = $localRepository
}
