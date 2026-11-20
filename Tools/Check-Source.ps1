<#
.SYNOPSIS
Static check of the source tree: every PowerShell file parses, both manifests are valid, and the
exported commands are exactly the files in PASeasyInstall\Public.
.DESCRIPTION
Read-only. Contacts no server, opens no window and needs no vendor media. It checks:
  1. every .ps1, .psm1 and .psd1 under PASeasyInstall, PASeasyInstall.UI, Tools and Tests, and
     Start-PASeasyInstall.ps1, with the PowerShell parser;
  2. both module manifests (Test-ModuleManifest; the UI manifest needs NativeHTMLKit.UI installed,
     otherwise only its data is read);
  3. FunctionsToExport of PASeasyInstall.psd1 == base names of PASeasyInstall\Public\*.ps1, and every
     public file defines the function it is named after;
  4. the core module imports and exports exactly that list;
  5. optionally (-Analyze, or automatically when PSScriptAnalyzer is installed) a short list of
     PSScriptAnalyzer rules. Findings are warnings unless -FailOnAnalyzer is given.
Used by Tools\Invoke-CITests.ps1. Throws on the first failed check.
.EXAMPLE
.\Tools\Check-Source.ps1
.EXAMPLE
.\Tools\Check-Source.ps1 -Analyze -FailOnAnalyzer
#>
[CmdletBinding()]
param(
    [switch]$Analyze,
    [switch]$SkipAnalyzer,
    [switch]$FailOnAnalyzer
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$coreRoot = Join-Path $repo 'PASeasyInstall'
$uiRoot = Join-Path $repo 'PASeasyInstall.UI'
$coreManifest = Join-Path $coreRoot 'PASeasyInstall.psd1'
$uiManifest = Join-Path $uiRoot 'PASeasyInstall.UI.psd1'

# 1. Parser
$files = @()
foreach ($folder in @($coreRoot, $uiRoot, (Join-Path $repo 'Tools'), (Join-Path $repo 'Tests'))) {
    $files += @(Get-ChildItem -LiteralPath $folder -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') })
}
$files += Get-Item -LiteralPath (Join-Path $repo 'Start-PASeasyInstall.ps1')
$parseProblems = @()
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in @($parseErrors)) {
        $parseProblems += ('{0}:{1}: {2}' -f $file.FullName, $parseError.Extent.StartLineNumber, $parseError.Message)
    }
}
if ($parseProblems.Count) {
    throw ("PowerShell parse errors:`n" + ($parseProblems -join "`n"))
}

# 2. Manifests
$core = Test-ModuleManifest -Path $coreManifest -ErrorAction Stop
$coreData = Import-PowerShellDataFile -Path $coreManifest
if ($coreData.ContainsKey('RequiredModules') -and @($coreData.RequiredModules).Count) {
    throw 'PASeasyInstall.psd1 must not require other modules (the core has no GUI dependency)'
}
$uiData = Import-PowerShellDataFile -Path $uiManifest
if ([string]$uiData.ModuleVersion -ne [string]$coreData.ModuleVersion) {
    throw "Version mismatch: PASeasyInstall $($coreData.ModuleVersion), PASeasyInstall.UI $($uiData.ModuleVersion)"
}
if ((@($uiData.FunctionsToExport) -join ',') -ne 'Start-PASeasyInstall') {
    throw 'PASeasyInstall.UI must export exactly Start-PASeasyInstall'
}
$uiTested = $false
if (Get-Module -ListAvailable -Name NativeHTMLKit.UI) {
    Test-ModuleManifest -Path $uiManifest -ErrorAction Stop | Out-Null
    $uiTested = $true
} else {
    Write-Warning 'NativeHTMLKit.UI is not installed: the PASeasyInstall.UI manifest was read but not tested.'
}

# 3. Export list == Public folder
$publicFiles = @(Get-ChildItem -LiteralPath (Join-Path $coreRoot 'Public') -Filter '*.ps1' -File)
$publicNames = @($publicFiles | ForEach-Object { $_.BaseName } | Sort-Object)
$exportNames = @($coreData.FunctionsToExport | Sort-Object)
$difference = @(Compare-Object -ReferenceObject $publicNames -DifferenceObject $exportNames)
if ($difference.Count) {
    $text = @($difference | ForEach-Object { $_.InputObject + ' (' + $_.SideIndicator + ')' }) -join ', '
    throw "FunctionsToExport and the Public folder differ ('<=' only a file, '=>' only in the manifest): $text"
}
foreach ($file in $publicFiles) {
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    $functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false) | ForEach-Object { $_.Name })
    if ($functions.Count -ne 1 -or $functions[0] -ne $file.BaseName) {
        throw "$($file.Name) must define exactly one function, named $($file.BaseName) (found: $($functions -join ', '))"
    }
}

# 4. Import
Import-Module $coreManifest -Force -ErrorAction Stop
$exported = @((Get-Command -Module PASeasyInstall).Name | Sort-Object)
if (($exported -join ',') -ne ($publicNames -join ',')) {
    throw "The imported module exports: $($exported -join ', '). Expected: $($publicNames -join ', ')"
}
if (Get-Module -Name NativeHTMLKit.UI, NativeHTMLKit) {
    Write-Warning 'NativeHTMLKit is loaded in this session; the core module itself does not load it.'
}

# 5. PSScriptAnalyzer (optional)
$analyzerFindings = 0
$analyzerAvailable = [bool](Get-Module -ListAvailable -Name PSScriptAnalyzer)
if ($Analyze -and -not $analyzerAvailable) {
    throw '-Analyze needs PSScriptAnalyzer (Install-Module PSScriptAnalyzer -Scope CurrentUser)'
}
if ($analyzerAvailable -and -not $SkipAnalyzer) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    $rules = @(
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingInvokeExpression',
        'PSAvoidUsingCmdletAliases',
        'PSUseDeclaredVarsMoreThanAssignments',
        'PSAvoidGlobalVars',
        'PSUseBOMForUnicodeEncodedFile',
        'PSMissingModuleManifestField'
    )
    $findings = @()
    foreach ($folder in @($coreRoot, $uiRoot)) {
        $findings += @(Invoke-ScriptAnalyzer -Path $folder -Recurse -IncludeRule $rules)
    }
    $analyzerFindings = $findings.Count
    foreach ($finding in $findings) {
        Write-Warning ('{0}:{1} {2}: {3}' -f $finding.ScriptPath, $finding.Line, $finding.RuleName, $finding.Message)
    }
    if ($analyzerFindings -and $FailOnAnalyzer) {
        throw "PSScriptAnalyzer reported $analyzerFindings finding(s)"
    }
}

$analyzerText = 'not run'
if ($analyzerAvailable -and -not $SkipAnalyzer) {
    $analyzerText = "$analyzerFindings finding(s)"
}
$uiText = 'read only'
if ($uiTested) {
    $uiText = 'tested'
}
Write-Output ("PASS: $($files.Count) files parsed; PASeasyInstall $($core.Version) manifest tested, PASeasyInstall.UI manifest $uiText; " +
    "$($publicNames.Count) public commands match the Public folder; PSScriptAnalyzer: $analyzerText. No server was contacted.")
