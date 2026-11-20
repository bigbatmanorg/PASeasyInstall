# Release packaging: Gallery stage content, forbidden-content scan, umbrella command surface and the
# credential requirements Invoke-PASInstall prompts for. No servers and no network.
BeforeAll {
    $script:repo = Split-Path -Parent $PSScriptRoot
    $script:expected = @('Start-PASInstall','Invoke-PASInstall','New-PASDeploymentConfiguration','Get-PASMediaInventory',
        'Get-PASMediaSelection','Test-PASEnvironment','Get-PASEnvironmentPlan','Save-PASEnvironment','Start-PASEnvironment',
        'Get-PASEnvironmentSnapshot','Get-PASEnvironmentEvents','Get-PASStageCatalog','Resume-PASDeployment',
        'Test-PASEnvironmentHealth','Export-PASRunData','Close-PASDeployment')
    function Copy-RepoForBuild([string]$To) {
        New-Item -ItemType Directory -Path $To -Force | Out-Null
        foreach ($item in 'PASeasyInstall.psd1','PASeasyInstall.psm1','en-US','Modules','Tools','Docs') {
            $src = Join-Path $script:repo $item
            if ($item -eq 'Docs') { New-Item -ItemType Directory -Path (Join-Path $To 'Docs') -Force | Out-Null
                Get-ChildItem -LiteralPath $src -Filter 'THIRD_PARTY_*.txt' | Copy-Item -Destination (Join-Path $To 'Docs'); continue }
            if ($item -eq 'Tools') { New-Item -ItemType Directory -Path (Join-Path $To 'Tools') -Force | Out-Null
                Copy-Item -LiteralPath (Join-Path $src 'Build-GalleryPackage.ps1') -Destination (Join-Path $To 'Tools'); continue }
            Copy-Item -LiteralPath $src -Destination $To -Recurse -Force
        }
    }
    $script:stageInfo = & (Join-Path $script:repo 'Tools/Build-GalleryPackage.ps1') -Output (Join-Path $TestDrive 'dist') -AllowMissingLicense
    Import-Module (Join-Path $script:repo 'PASeasyInstall.psd1') -Force 3>$null
}
AfterAll {
    # The umbrella loads NativeHTMLKit.UI as a required module; unload it so later suites start clean.
    Remove-Module PASeasyInstall,PASeasyInstall.UI,NativeHTMLKit.UI,NativeHTMLKit -Force -ErrorAction SilentlyContinue
}

Describe 'Gallery package stage' {
    It 'contains the umbrella module, engine, orchestrator, UI and the kept PTA module' {
        $s = $script:stageInfo.Stage
        foreach ($rel in 'PASeasyInstall.psd1','PASeasyInstall.psm1','en-US/about_PASeasyInstall.help.txt',
                         'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1','Modules/PASeasyInstall.Orchestrator/PASeasyInstall.Orchestrator.psd1',
                         'Modules/PASeasyInstall.UI/App.ps1','Modules/PASeasyInstall.PTA/PASeasyInstall.PTA.psd1') {
            Test-Path -LiteralPath (Join-Path $s $rel) | Should -BeTrue -Because $rel
        }
        Test-Path -LiteralPath $script:stageInfo.Inventory | Should -BeTrue
        $script:stageInfo.Version | Should -Match '^\d+\.\d+\.\d+(-[A-Za-z0-9]+)?$'
    }
    It 'leaves out tests, tools, docs and UI test helpers' {
        $files = @(Get-ChildItem -LiteralPath $script:stageInfo.Stage -Recurse -File)
        @($files | Where-Object { $_.Name -like '*.Tests.ps1' }).Count | Should -Be 0
        @($files | Where-Object { $_.FullName -match '[\\/]Legacy[\\/]' }).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $script:stageInfo.Stage 'Tools') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:stageInfo.Stage 'Tests') | Should -BeFalse
    }
    It 'refuses a lab address planted in the module source' {
        $copy = Join-Path $TestDrive 'planted'
        Copy-RepoForBuild $copy
        Add-Content -LiteralPath (Join-Path $copy 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psm1') ("`n# " + '10.0.' + '110.5')
        { & (Join-Path $copy 'Tools/Build-GalleryPackage.ps1') -Output (Join-Path $TestDrive 'planted-dist') -AllowMissingLicense } | Should -Throw '*lab address*'
    }
    It 'refuses vendor media in the module tree' {
        $copy = Join-Path $TestDrive 'media'
        Copy-RepoForBuild $copy
        [IO.File]::WriteAllBytes((Join-Path $copy 'Modules/PASeasyInstall.Core/installer.zip'), [byte[]](80,75,3,4))
        { & (Join-Path $copy 'Tools/Build-GalleryPackage.ps1') -Output (Join-Path $TestDrive 'media-dist') -AllowMissingLicense } | Should -Throw '*forbidden file type*'
    }
}

Describe 'Umbrella command surface' {
    It 'exports exactly the public commands and nothing PTA-related' {
        $names = @((Get-Command -Module PASeasyInstall).Name | Sort-Object)
        ($names -join ',') | Should -Be (($script:expected | Sort-Object) -join ',')
        @($names | Where-Object { $_ -match 'PTA' }).Count | Should -Be 0
    }
    It 'documents every public command with a synopsis and an example' {
        foreach ($name in $script:expected) {
            $h = Get-Help $name -Full
            ([string]$h.Synopsis).Trim() | Should -Not -BeNullOrEmpty -Because $name
            $examples = @(); if ($h.PSObject.Properties['examples'] -and $h.examples) { $examples = @($h.examples.example | Where-Object { $_ }) }
            $examples.Count | Should -BeGreaterThan 0 -Because $name
            ([string]$h.Synopsis).Trim() | Should -Not -BeLike "$name *" -Because "$name needs a real synopsis, not its syntax"
        }
    }
    It 'refuses PTA in the stage catalog' {
        { Get-PASStageCatalog -Component PTA } | Should -Throw
    }
}

Describe 'Invoke-PASInstall credential requirements' {
    BeforeAll {
        function New-Cfg([switch]$Composed, [string]$Profile = 'Lab') {
            $c = [ordered]@{ name = 'T'; security = [ordered]@{ profile = $Profile; overrides = [ordered]@{} }
                vault = [ordered]@{ address = '192.0.2.11'; existing = $false }
                activeDirectory = [ordered]@{ mode = 'Existing'; join = @('psm01'); joinUser = 'LAB\Administrator' }
                hosts = [ordered]@{
                    vault01 = [ordered]@{ address = '192.0.2.11'; os = 'Windows'; user = 'Administrator'; credentialRef = 'vault01' }
                    dr01    = [ordered]@{ address = '192.0.2.12'; os = 'Windows'; user = 'Administrator'; credentialRef = 'dr01' }
                    psm01   = [ordered]@{ address = '192.0.2.21'; os = 'Windows'; user = 'Administrator'; credentialRef = 'psm01' }
                    psmp01  = [ordered]@{ address = '192.0.2.31'; os = 'Linux'; user = 'root'; credentialRef = 'psmp01'; identityFile = 'k'; knownHostsFile = 'kh' } }
                components = @([ordered]@{ id = 'vault'; type = 'Vault'; host = 'vault01' }, [ordered]@{ id = 'dr'; type = 'DRVault'; host = 'dr01' },
                    [ordered]@{ id = 'psm01'; type = 'PSM'; host = 'psm01' }, [ordered]@{ id = 'psmp01'; type = 'PSMP'; host = 'psmp01' }) }
            if ($Composed) { $c.execution = [ordered]@{ mode = 'Sequential' } }
            return $c
        }
    }
    It 'asks for every Windows server, the domain PSM installer and the Vault/DR/join secrets' {
        $req = & (Get-Module PASeasyInstall) { param($c) Get-PASInstallRequirement $c } (New-Cfg)
        @($req | Where-Object Kind -eq 'Credential' | ForEach-Object Key) | Should -Be @('vault01','dr01','psm01','PSMDomainInstaller')
        @($req | Where-Object Kind -eq 'Secret' | ForEach-Object Key) | Should -Be @('VaultAdmin','VaultMaster','DRPassword','DomainJoinPassword')
    }
    It 'asks for the Linux password only for composed deployments (one-time key authorisation)' {
        $req = & (Get-Module PASeasyInstall) { param($c) Get-PASInstallRequirement $c } (New-Cfg -Composed)
        @($req | Where-Object Key -eq 'psmp01').Count | Should -Be 1
    }
    It 'uses one lab password for everything and maps Windows accounts to .\user for WinRM' {
        $pw = ConvertTo-SecureString 'Example-Passw0rd!' -AsPlainText -Force
        $auth = & (Get-Module PASeasyInstall) { param($c, $p) Resolve-PASInstallCredential $c @{} @{} $p } (New-Cfg -Composed) $pw
        $auth.Credentials['vault01'].UserName | Should -Be '.\Administrator'
        $auth.Credentials['psmp01'].UserName | Should -Be 'root'
        $auth.Credentials['PSMDomainInstaller'].UserName | Should -Be 'LAB\Administrator'
        $auth.Secrets.Keys.Count | Should -Be 4
    }
    It 'refuses the one-password shortcut outside the Lab profile' {
        $pw = ConvertTo-SecureString 'Example-Passw0rd!' -AsPlainText -Force
        { & (Get-Module PASeasyInstall) { param($c, $p) Resolve-PASInstallCredential $c @{} @{} $p } (New-Cfg -Profile Secure) $pw } | Should -Throw '*Lab*'
    }
}

Describe 'Export-PASRunData' {
    It 'exports journals, leaves out envelopes and refuses files with secrets' {
        $root = Join-Path $TestDrive 'data'
        $id = 'a' * 32
        $run = Join-Path $root "Runs/$id"
        New-Item -ItemType Directory -Path (Join-Path $run 'primary') -Force | Out-Null
        '{"status":"Succeeded"}' | Set-Content (Join-Path $run 'run-v2.json')
        '{"name":"T"}' | Set-Content (Join-Path $run 'config.json')
        '{"event":"x"}' | Set-Content (Join-Path $run 'primary/events.jsonl')
        '{"credentials":{"vault01":{"user":"a","cipher":"01000000d08c9ddf0115d1118c7a00c04fc297eb0100000000"}}}' | Set-Content (Join-Path $run 'credentials-1.json')
        '{"password":"Example-Passw0rd!"}' | Set-Content (Join-Path $run 'leak.json')
        $zip = Join-Path $TestDrive 'out.zip'
        $r = Export-PASRunData -RunId $id -Path $zip -DataRoot $root
        $r.Files | Should -Be 3
        @($r.Excluded | ForEach-Object File) | Should -Contain "runs/$id/leak.json"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try { $names = @($z.Entries | ForEach-Object FullName) } finally { $z.Dispose() }
        $names | Should -Contain "runs/$id/primary/events.jsonl"
        @($names | Where-Object { $_ -match 'credentials-|leak|\\' }).Count | Should -Be 0
    }
}
