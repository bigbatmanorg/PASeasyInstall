# Publishes only to a unique LOCAL directory repository. Never publishes to PSGallery.
[CmdletBinding()]
param([string]$RepositoryRoot=(Split-Path -Parent $PSScriptRoot),[string]$Revision='HEAD',
      [string]$OutputDirectory,[switch]$StageOnly,[switch]$AllowBuildToolBootstrap,[switch]$DefinitionsOnly)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Packaging.Common.ps1')
function Invoke-PASeasyPackageGit {
    param([string[]]$Arguments)
    # Git for Windows commonly defaults to CRLF conversion, including ZIP export.
    # Packaging must preserve committed blob bytes regardless of local checkout policy.
    $lines=@(& $script:PackageGit -c core.autocrlf=false -c core.eol=lf -C $script:PackageGitRoot @Arguments 2>&1)
    if($LASTEXITCODE -ne 0){throw 'Git source operation failed; inspect the selected repository/revision'}
    return $lines
}
if($DefinitionsOnly){return}
if(-not $StageOnly -and ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSEdition -ne 'Desktop')){throw 'Package publication qualification requires Windows PowerShell5.1; StageOnly is cross-platform'}
if($Revision -notmatch '^[A-Za-z0-9][A-Za-z0-9_./-]{0,200}$'){throw 'Invalid committed revision selector'}
$script:PackageGit=(Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
$script:PackageGitRoot=Assert-PASeasyPackageLocalPath $RepositoryRoot
$output=Assert-PASeasyPackageLocalPath $OutputDirectory
if(Test-Path -LiteralPath $output){throw 'Output directory already exists; preserve prior artifacts and choose a new path'}
$commit=[string](Invoke-PASeasyPackageGit -Arguments @('rev-parse','--verify',($Revision+'^{commit}')))
if($commit -notmatch '^[a-f0-9]{40,64}$'){throw 'Selected source is not a Git commit'}
$format=[string](Invoke-PASeasyPackageGit -Arguments @('rev-parse','--show-object-format'))
if($format -notin @('sha1','sha256')){throw 'Unsupported Git object format'}
$tracked=@(Invoke-PASeasyPackageGit -Arguments @('ls-tree','-rl',$commit,'--','PASeasyInstall'))
$source=@();$total=0;$paths=@{}
foreach($line in $tracked){
    if([string]$line -notmatch '^([0-9]{6}) blob ([a-f0-9]{40,64})\s+([0-9]+)\t(.+)$'){throw 'Module tree contains a symlink, submodule or unsupported tracked entry'}
    $mode=$Matches[1];$blob=$Matches[2];$length=[long]$Matches[3];$path=$Matches[4]
    if($mode -notin @('100644','100755') -or -not(Test-PASeasyPackageSourcePath $path)){throw "Tracked module file is outside the package allowlist: $path"}
    if($paths.ContainsKey($path)){throw 'Case-colliding package paths are unsupported on Windows'}
    $paths[$path]=$true
    if($length -gt 2097152){throw 'Tracked source exceeds the2MiB file limit'}
    $total+=$length
    $source+=@{Relative=$path.Substring('PASeasyInstall/'.Length);GitBlob=$blob;Bytes=$length}
}
if($source.Count -lt 10 -or $total -gt 67108864){throw 'Unexpected module source count/size'}
$dirty=(@(Invoke-PASeasyPackageGit -Arguments @('status','--porcelain','--untracked-files=normal')).Count -gt 0)
$output=New-PASeasyPackagePrivateOutput $output
$archive=Join-Path $output 'tracked-source.zip'
$null=Invoke-PASeasyPackageGit -Arguments @('archive','--format=zip',('--output='+$archive),$commit,'--','PASeasyInstall')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$stage=Join-Path $output 'stage';$moduleRoot=Join-Path $stage 'PASeasyInstall'
$zip=[IO.Compression.ZipFile]::OpenRead($archive)
try{
    $files=@($zip.Entries|Where-Object {-not $_.FullName.EndsWith('/')})
    if($files.Count -ne $source.Count){throw 'Archive differs from the approved tracked file list (including export-ignore attributes)'}
    foreach($file in $source){
        $entry=$zip.GetEntry('PASeasyInstall/'+$file.Relative)
        if(-not $entry -or $entry.Length -ne $file.Bytes){throw 'Archive source entry is missing or has changed size'}
        $memory=[IO.MemoryStream]::new();$stream=$entry.Open()
        try{$stream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
        Assert-PASeasyPackageText $bytes
        $header=[Text.Encoding]::UTF8.GetBytes(('blob '+$bytes.Length+[char]0))
        if((Get-PASeasyPackageHash ([byte[]]($header+$bytes)) $format.ToUpperInvariant()) -cne $file.GitBlob){throw 'Git archive changed source bytes (including export-subst attributes)'}
        $file.SHA256=Get-PASeasyPackageHash $bytes
        $destination=Join-Path $moduleRoot $file.Relative
        $null=New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
        [IO.File]::WriteAllBytes($destination,$bytes)
    }
}finally{$zip.Dispose()}
if($env:OS -ne 'Windows_NT'){& chmod -R go-rwx -- $stage;if($LASTEXITCODE -ne 0){throw 'Cannot restrict private Unix source stage'}}
Assert-PASeasyPackageStagedFiles -ModuleRoot $moduleRoot -Files $source
$manifest=Import-PowerShellDataFile (Join-Path $moduleRoot 'PASeasyInstall.psd1')
if($manifest.RootModule -ne 'PASeasyInstall.psm1' -or ($manifest.ContainsKey('RequiredModules') -and @($manifest.RequiredModules).Count)){throw 'Package must remain a single module without RequiredModules'}
$version=[string]$manifest.ModuleVersion
$digest=Get-PASeasyPackageSourceDigest $moduleRoot
$inventoryDigest=Get-PASeasyPackageInventoryDigest $source
$inventoryPath=Join-Path $output 'source-files.json'
Write-PASeasyPackageJson $inventoryPath @{SchemaVersion=1;Commit=$commit;SourceDigest=$digest;InventorySHA256=$inventoryDigest;Version=$version;Files=@($source)}
$proof=[ordered]@{SchemaVersion=1;Result='StagedTrackedSource';Commit=$commit;WorkingTreeDirtyIgnored=$dirty;SourceDigest=$digest;InventorySHA256=$inventoryDigest;Version=$version;SourceFiles=$source.Count;Stage=$moduleRoot;Package='';PackageSHA256='';Consumer='';ConsumerProof='';LocalOnly=$true;BootstrapAllowed=[bool]$AllowBuildToolBootstrap;BuildTools=@{};Scope='Committed-source staging only; package/consumer NotTested';CapturedUtc=[DateTime]::UtcNow.ToString('o')}
if(-not $StageOnly){
    $publish=Get-Command Publish-Module -ErrorAction Stop
    foreach($command in @('Register-PSRepository','Unregister-PSRepository','Save-Module','Get-PSRepository')){$null=Get-Command $command -ErrorAction Stop}
    $nugetCandidates=@((Join-Path $env:LOCALAPPDATA 'Microsoft/Windows/PowerShell/PowerShellGet/NuGet.exe'),(Join-Path $env:ProgramData 'Microsoft/Windows/PowerShell/PowerShellGet/NuGet.exe'))
    $nuget=@($nugetCandidates|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf})
    $providers=@(Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)
    if(-not $providers.Count -and -not $AllowBuildToolBootstrap){throw 'Build-only NuGet package provider is missing; prepare tooling or explicitly allow build bootstrap'}
    if(-not $nuget.Count -and -not $AllowBuildToolBootstrap){throw 'Build-only NuGet.exe is missing. Prepare Microsoft PowerShellGet tooling or explicitly use AllowBuildToolBootstrap; the runtime has no NuGet dependency.'}
    $proof.BuildTools=@{PowerShell=[string]$PSVersionTable.PSVersion;PowerShellGet=[string]$publish.Version;NuGetExePresentBefore=($nuget.Count -gt 0);NuGetProviderPresentBefore=($providers.Count -gt 0)}
    $feed=Join-Path $output 'feed';$consumer=Join-Path $output 'consumer'
    $null=New-Item $feed -ItemType Directory;$null=New-Item $consumer -ItemType Directory
    $repository='PAeasyLocalBuild'+[guid]::NewGuid().ToString('N');$registered=$false
    try{
        Register-PSRepository -Name $repository -SourceLocation $feed -PublishLocation $feed -InstallationPolicy Trusted
        $registered=$true
        $registration=Get-PSRepository -Name $repository -ErrorAction Stop
        if([IO.Path]::GetFullPath([string]$registration.SourceLocation) -ine $feed -or [IO.Path]::GetFullPath([string]$registration.PublishLocation) -ine $feed){throw 'Local repository registration differs from the fixed output feed'}
        Publish-Module -Path $moduleRoot -Repository $repository -NuGetApiKey 'local-directory-only' -Force
        $packages=@(Get-ChildItem -LiteralPath $feed -Filter '*.nupkg' -File)
        if($packages.Count -ne 1 -or $packages[0].Name -ine ('PASeasyInstall.'+$version+'.nupkg')){throw 'Expected exactly one local module package'}
        $proof.Package=$packages[0].FullName;$proof.PackageSHA256=(Get-FileHash $proof.Package -Algorithm SHA256).Hash.ToLowerInvariant()
        Save-Module -Name PASeasyInstall -RequiredVersion $version -Repository $repository -Path $consumer -Force
        $proof.Consumer=$consumer
    }finally{if($registered){Unregister-PSRepository -Name $repository -ErrorAction Stop}}
    $proof.ConsumerProof=Join-Path $output 'installed-consumer-proof.json'
    $probe=Join-Path $PSScriptRoot 'Test-InstalledModulePackage.ps1'
    $exe=Join-Path $PSHOME 'powershell.exe'
    $consumerOutput=@(& $exe -NoProfile -NonInteractive -File $probe -ConsumerRoot $consumer -ExpectedVersion $version -ExpectedSourceDigest $digest -SourceFileInventory $inventoryPath -OutputPath $proof.ConsumerProof)
    $consumerExitCode=$LASTEXITCODE
    [IO.File]::WriteAllLines((Join-Path $output 'consumer-process.log'),[string[]]$consumerOutput,[Text.UTF8Encoding]::new($false))
    if($consumerExitCode -ne 0 -or -not(Test-Path -LiteralPath $proof.ConsumerProof)){throw 'Fresh installed-consumer probe failed; preserve artifacts for inspection'}
    $observed=Get-Content $proof.ConsumerProof -Raw|ConvertFrom-Json
    if(-not $observed.Passed){throw 'Consumer did not report a passing offline API probe'}
    $proof.Result='LocalPackageAndInstalledConsumerPassed'
    $proof.Scope='Fresh process and isolated installed-module path on existing controller; clean VM and remote Gallery publication NotTested'
}
Write-PASeasyPackageJson (Join-Path $output 'build-proof.json') $proof
[pscustomobject]$proof
