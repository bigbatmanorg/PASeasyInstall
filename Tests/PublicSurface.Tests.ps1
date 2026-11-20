# The public surface of the core module: what is exported, that it is documented, and that the module
# stands alone (no GUI dependency). No server is contacted.
BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $publicCommands = @(Get-ChildItem -LiteralPath (Join-Path $PASModuleRoot 'Public') -Filter '*.ps1' -File | ForEach-Object { @{ Name = $_.BaseName } })
}
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    $script:manifest = Import-PowerShellDataFile -Path $PASModuleManifest
    $script:publicNames = @(Get-ChildItem -LiteralPath (Join-Path $PASModuleRoot 'Public') -Filter '*.ps1' -File | ForEach-Object { $_.BaseName } | Sort-Object)
}

Describe 'Public command list' {
    It 'exports exactly one command per file in the Public folder' {
        (@($script:manifest.FunctionsToExport | Sort-Object) -join ',') | Should -Be ($script:publicNames -join ',')
        (@((Get-Command -Module PASeasyInstall).Name | Sort-Object) -join ',') | Should -Be ($script:publicNames -join ',')
    }
    It 'exports no cmdlets, variables or aliases' {
        @($script:manifest.CmdletsToExport).Count | Should -Be 0
        @($script:manifest.VariablesToExport).Count | Should -Be 0
        @($script:manifest.AliasesToExport).Count | Should -Be 0
        @(Get-Command -Module PASeasyInstall -CommandType Alias).Count | Should -Be 0
    }
    It 'uses the PAS prefix and none of the old names' {
        foreach ($name in $script:publicNames) {
            $name | Should -Match '^(Install|New|Test|Get|Export|Import|Wait|Resume|Stop)-PAS[A-Z][A-Za-z]+$'
            $name | Should -Not -Match 'PASeasy|PAExec|PAEasy|PASEnvironment|PASDeployment|PTA'
        }
        foreach ($old in 'Invoke-PASeasyInstall', 'Test-PASEnvironment', 'Get-PASEnvironmentPlan', 'Save-PASEnvironment',
                         'Start-PASEnvironment', 'Get-PASEnvironmentSnapshot', 'Get-PASEnvironmentEvents',
                         'Test-PASEnvironmentHealth', 'Export-PASRunData', 'Close-PASDeployment', 'Start-PASInstall', 'Invoke-PASInstall') {
            Get-Command -Module PASeasyInstall -Name $old -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because $old
        }
    }
    It 'keeps the run controller and the engine private' {
        Get-Command Invoke-PASRunController -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Get-Command Invoke-PASWorkflow -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        (InModuleScope PASeasyInstall { (Get-Command Invoke-PASRunController -CommandType Function).Name }) | Should -BeExactly 'Invoke-PASRunController'
    }
}

Describe 'Help of <Name>' -ForEach $publicCommands {
    It 'has a real synopsis and at least one example' {
        $help = Get-Help $Name -Full
        $synopsis = ([string]$help.Synopsis).Trim()
        $synopsis | Should -Not -BeNullOrEmpty
        $synopsis | Should -Not -BeLike "$Name *" -Because "$Name needs a synopsis, not its syntax"
        $examples = @()
        if ($help.PSObject.Properties['examples'] -and $help.examples) {
            $examples = @($help.examples.example | Where-Object { $_ })
        }
        $examples.Count | Should -BeGreaterThan 0
    }
    It 'is defined in a file of the same name, with comment-based help' {
        $text = Get-Content -LiteralPath (Join-Path (Join-Path $PASModuleRoot 'Public') ($Name + '.ps1')) -Raw
        $text | Should -Match ('(?m)^function ' + [regex]::Escape($Name) + '\b')
        $text | Should -Match '\.SYNOPSIS'
        $text | Should -Match '\.EXAMPLE'
    }
}

Describe 'The core module stands alone' {
    It 'requires no other module' {
        $required = @()
        if ($script:manifest.ContainsKey('RequiredModules')) { $required = @($script:manifest.RequiredModules) }
        $required.Count | Should -Be 0
    }
    It 'never imports NativeHTMLKit or the UI module from its own files' {
        $hits = @(Get-ChildItem -LiteralPath $PASModuleRoot -Recurse -File -Include '*.ps1', '*.psm1' |
            Select-String -Pattern 'Import-Module\s+\S*(NativeHTMLKit|PASeasyInstall\.UI)')
        $hits | Should -BeNullOrEmpty
    }
    It 'imports in a fresh process without loading NativeHTMLKit' -Skip:($env:OS -ne 'Windows_NT') {
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $command = "Import-Module '" + $PASModuleManifest.Replace("'", "''") + "' -ErrorAction Stop; " +
            "'COMMANDS=' + @(Get-Command -Module PASeasyInstall).Count; 'KIT=' + @(Get-Module NativeHTMLKit*).Count"
        $output = @(& $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command 2>&1 | ForEach-Object { [string]$_ })
        $LASTEXITCODE | Should -Be 0
        $output | Should -Contain ('COMMANDS=' + $script:publicNames.Count)
        $output | Should -Contain 'KIT=0'
    }
}
