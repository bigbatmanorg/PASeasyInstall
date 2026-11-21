# Release packaging: the two Gallery package stages, the forbidden-content scan, the credentials a
# configuration asks for, and the diagnostics export. No servers and no network.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:repo = $PASRepoRoot
    function Copy-RepoForBuild([string]$To) {
        New-Item -ItemType Directory -Path (Join-Path $To 'Tools') -Force | Out-Null
        foreach ($item in 'PASeasyInstall', 'PASeasyInstall.UI') {
            Copy-Item -LiteralPath (Join-Path $script:repo $item) -Destination $To -Recurse -Force
        }
        Copy-Item -LiteralPath (Join-Path $script:repo 'Tools/Build-GalleryPackage.ps1') -Destination (Join-Path $To 'Tools')
    }
    $script:build = & (Join-Path $script:repo 'Tools/Build-GalleryPackage.ps1') -Output (Join-Path $TestDrive 'dist') -AllowMissingLicense 3>$null
    $script:core = @($script:build.Packages | Where-Object Module -eq 'PASeasyInstall')[0]
    $script:ui = @($script:build.Packages | Where-Object Module -eq 'PASeasyInstall.UI')[0]
    Import-PASTestModule
}

Describe 'Gallery package stages' {
    It 'stages the core module first and the UI module second, with one version' {
        @($script:build.Packages | ForEach-Object Module) | Should -Be @('PASeasyInstall', 'PASeasyInstall.UI')
        $script:build.Version | Should -Match '^\d+\.\d+\.\d+(-[A-Za-z0-9]+)?$'
        (Import-PowerShellDataFile (Join-Path $script:ui.Stage 'PASeasyInstall.UI.psd1')).ModuleVersion |
            Should -Be (Import-PowerShellDataFile (Join-Path $script:core.Stage 'PASeasyInstall.psd1')).ModuleVersion
    }
    It 'puts the commands, recipes, help and license into the core package' {
        foreach ($rel in 'PASeasyInstall.psd1', 'PASeasyInstall.psm1', 'en-US/about_PASeasyInstall.help.txt', 'LICENSE.txt',
            'Public/Install-PASVault.ps1', 'Private/Run/Run.ps1', 'Controllers/Invoke-PASRunController.ps1',
            'Recipes/Vault/Workflows/VaultPrimaryOnly.psd1', 'Recipes/LinuxComponent/Task.sh') {
            Test-Path -LiteralPath (Join-Path $script:core.Stage $rel) | Should -BeTrue -Because $rel
        }
        Test-Path -LiteralPath $script:core.Inventory | Should -BeTrue
    }
    It 'puts the desktop and its Mock backend into the UI package' {
        foreach ($rel in 'PASeasyInstall.UI.psd1', 'PASeasyInstall.UI.psm1', 'App.ps1', 'Model.ps1', 'Views.ps1', 'Web/index.html', 'Web/style.css',
            'Backend/Backend.Contract.ps1', 'Backend/Mock/PASeasyInstall.Mock.psd1') {
            Test-Path -LiteralPath (Join-Path $script:ui.Stage $rel) | Should -BeTrue -Because $rel
        }
        Test-Path -LiteralPath $script:ui.Inventory | Should -BeTrue
    }
    It 'keeps the core package free of any module dependency' {
        $data = Import-PowerShellDataFile (Join-Path $script:core.Stage 'PASeasyInstall.psd1')
        $required = @()
        if ($data.ContainsKey('RequiredModules')) { $required = @($data.RequiredModules) }
        $required.Count | Should -Be 0
        $loads = @(Get-ChildItem -LiteralPath $script:core.Stage -Recurse -File -Include '*.ps1', '*.psm1' |
                Select-String -Pattern 'Import-Module\s+NativeHTMLKit')
        $loads.Count | Should -Be 0
    }
    It 'leaves out tests, tools and docs' {
        foreach ($stage in $script:core.Stage, $script:ui.Stage) {
            $files = @(Get-ChildItem -LiteralPath $stage -Recurse -File)
            @($files | Where-Object { $_.Name -like '*.Tests.ps1' }).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $stage 'Tools') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $stage 'Tests') | Should -BeFalse
        }
    }
    It 'refuses a lab address planted in the module source' {
        $copy = Join-Path $TestDrive 'planted'
        Copy-RepoForBuild $copy
        Add-Content -LiteralPath (Join-Path $copy 'PASeasyInstall/PASeasyInstall.psm1') ("`n# " + '10.0.' + '110.5')
        { & (Join-Path $copy 'Tools/Build-GalleryPackage.ps1') -Output (Join-Path $TestDrive 'planted-dist') -AllowMissingLicense 3>$null } |
            Should -Throw '*lab address*'
    }
    It 'refuses vendor media in a module folder' {
        $copy = Join-Path $TestDrive 'media'
        Copy-RepoForBuild $copy
        [IO.File]::WriteAllBytes((Join-Path $copy 'PASeasyInstall.UI/installer.zip'), [byte[]](80, 75, 3, 4))
        { & (Join-Path $copy 'Tools/Build-GalleryPackage.ps1') -Output (Join-Path $TestDrive 'media-dist') -AllowMissingLicense 3>$null } |
            Should -Throw '*forbidden file type*'
    }
}

Describe 'Credential requirements of a configuration' {
    BeforeAll {
        function New-Cfg([switch]$Composed, [string]$Profile = 'Lab') {
            $c = [ordered]@{ name = 'T'; security = [ordered]@{ profile = $Profile; overrides = [ordered]@{} }
                vault = [ordered]@{ address = '192.0.2.11'; existing = $false }
                activeDirectory = [ordered]@{ mode = 'Existing'; join = @('psm01'); joinUser = 'LAB\Administrator' }
                hosts = [ordered]@{
                    vault01 = [ordered]@{
                        address = '192.0.2.11'
                        os = 'Windows'
                        user = 'Administrator'
                        credentialRef = 'vault01'
                    }
                    dr01 = [ordered]@{
                        address = '192.0.2.12'
                        os = 'Windows'
                        user = 'Administrator'
                        credentialRef = 'dr01'
                    }
                    psm01 = [ordered]@{
                        address = '192.0.2.21'
                        os = 'Windows'
                        user = 'Administrator'
                        credentialRef = 'psm01'
                    }
                    psmp01 = [ordered]@{
                        address = '192.0.2.31'
                        os = 'Linux'
                        user = 'root'
                        credentialRef = 'psmp01'
                        identityFile = 'k'
                        knownHostsFile = 'kh'
                    }
                }
                components = @([ordered]@{
                        id = 'vault'
                        type = 'Vault'
                        host = 'vault01'
                    }, [ordered]@{
                        id = 'dr'
                        type = 'DRVault'
                        host = 'dr01'
                    },
                    [ordered]@{
                        id = 'psm01'
                        type = 'PSM'
                        host = 'psm01'
                    }, [ordered]@{
                        id = 'psmp01'
                        type = 'PSMP'
                        host = 'psmp01'
                    })
            }
            if ($Composed) { $c.execution = [ordered]@{ mode = 'Sequential' } }
            return $c
        }
    }
    It 'asks for every Windows server, the domain PSM installer and the Vault/DR/join secrets' {
        $req = & (Get-Module PASeasyInstall) { param($c) Get-PASInstallRequirement $c } (New-Cfg)
        @($req | Where-Object Kind -eq 'Credential' | ForEach-Object Key) | Should -Be @('vault01', 'dr01', 'psm01', 'PSMDomainInstaller')
        @($req | Where-Object Kind -eq 'Secret' | ForEach-Object Key) |
            Should -Be @('VaultAdmin', 'VaultMaster', 'DRPassword', 'DomainJoinPassword')
    }
    It 'asks for the Linux password only for composed configurations (one-time key authorisation)' {
        $req = & (Get-Module PASeasyInstall) { param($c) Get-PASInstallRequirement $c } (New-Cfg -Composed)
        @($req | Where-Object Key -eq 'psmp01').Count | Should -Be 1
    }
    It 'uses one lab password for everything and keeps the user names as entered' {
        $pw = ConvertTo-SecureString 'Example-Passw0rd!' -AsPlainText -Force
        $auth = & (Get-Module PASeasyInstall) { param(
                $c,
                $p
            ) Resolve-PASInstallCredential $c @{} @{} $p } (New-Cfg -Composed) $pw
        # The '.\Administrator' form for WinRM is applied later, in ConvertTo-PASControllerCredentialMap.
        $auth.Credentials['vault01'].UserName | Should -Be 'Administrator'
        $auth.Credentials['psmp01'].UserName | Should -Be 'root'
        $auth.Credentials['PSMDomainInstaller'].UserName | Should -Be 'LAB\Administrator'
        $auth.Secrets.Keys.Count | Should -Be 4
    }
    It 'refuses the one-password shortcut outside the Lab profile' {
        $pw = ConvertTo-SecureString 'Example-Passw0rd!' -AsPlainText -Force
        { & (Get-Module PASeasyInstall) { param(
                    $c,
                    $p
                ) Resolve-PASInstallCredential $c @{} @{} $p } (New-Cfg -Profile Secure) $pw } |
            Should -Throw '*Lab*'
    }
}

Describe 'Export-PASDiagnostics' {
    BeforeAll {
        $script:SavedDataRoot = $env:PAS_EASY_DATA_ROOT
        $env:PAS_EASY_DATA_ROOT = Join-Path $TestDrive 'data'
    }
    AfterAll { $env:PAS_EASY_DATA_ROOT = $script:SavedDataRoot }
    It 'exports journals, leaves out envelopes and refuses files with secrets' {
        $id = 'a' * 32
        $run = Join-Path $env:PAS_EASY_DATA_ROOT "Runs/$id"
        New-Item -ItemType Directory -Path (Join-Path $run 'primary') -Force | Out-Null
        '{"id":"' + $id + '","status":"Succeeded"}' | Set-Content (Join-Path $run 'run.json')
        '{"name":"T"}' | Set-Content (Join-Path $run 'config.json')
        '{"event":"x"}' | Set-Content (Join-Path $run 'primary/events.jsonl')
        '{"credentials":{"vault01":{"user":"a","cipher":"01000000d08c9ddf0115d1118c7a00c04fc297eb0100000000"}}}' |
            Set-Content (Join-Path $run 'credentials-1.json')
        '{"password":"Example-Passw0rd!"}' | Set-Content (Join-Path $run 'leak.json')
        $zip = Join-Path $TestDrive 'out.zip'
        $r = Export-PASDiagnostics -RunId $id -Path $zip
        $r.Files | Should -Be 3
        @($r.Excluded | ForEach-Object File) | Should -Contain "runs/$id/leak.json"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try { $names = @($z.Entries | ForEach-Object FullName) } finally { $z.Dispose() }
        $names | Should -Contain "runs/$id/primary/events.jsonl"
        @($names | Where-Object { $_ -match 'credentials-|leak|\\' }).Count | Should -Be 0
    }
}
