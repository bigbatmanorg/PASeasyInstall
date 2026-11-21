# The desktop window (PASeasyInstall\Desktop) and the public commands it calls. No window, no server, no vendor
# execution: synthetic media in TestDrive.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $repo = $PASRepoRoot
    $uiRoot = $PASUIModuleRoot
    $script:SavedDataRoot = $env:PAS_EASY_DATA_ROOT
    $env:PAS_EASY_DATA_ROOT = Join-Path $TestDrive 'data'
    Import-PASTestModule
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    function New-TestZip([string]$Path, [string[]]$Entries) {
        $dir = [IO.Path]::GetDirectoryName($Path)
        if (-not(Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Create)
        $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($e in $Entries) {
                $w = New-Object IO.StreamWriter($zip.CreateEntry($e).Open())
                $w.Write('synthetic ' + $e)
                $w.Dispose()
            }
        } finally {
            $zip.Dispose()
            $fs.Dispose()
        }
    }
    $media = Join-Path $TestDrive 'media'
    New-TestZip (Join-Path $media 'CorePAS/Vault/Server-Rls-v15.0.zip') @('setup.exe')
    New-TestZip (Join-Path $media 'CorePAS/Vault/PACLI-Rls-v15.0.zip') @('pacli.exe')
    New-TestZip (Join-Path $media 'CorePAS/Vault/Disaster Recovery-Rls-v15.0.zip') @('setup.exe')
    New-TestZip (Join-Path $media 'CorePAS/Password Vault Web Access/Password Vault Web Access-Rls-v15.0.zip') @('x')
    New-TestZip (Join-Path $media 'keys.zip') @('master/recpub.key', 'master/recprv.key')
    # Bundle: CPM/PSM/PSMP only inside; PVWA also loose (duplicate must be dropped).
    New-TestZip (Join-Path $media 'Privileged Access Manager Self-Hosted_15.0.zip') @(
        'CorePAS/Password Vault Web Access/Password Vault Web Access-Rls-v15.0.zip',
        'CorePAS/Central Policy Manager/Central Policy Manager-Rls-v15.0.zip',
        'CorePAS/Privileged Session Manager/Privileged Session Manager-Rls-v15.0.zip',
        'CorePAS/Privileged Session Manager for SSH/PrivilegedSessionManagerSSHProxy-RHELinux9-Intel64-Rls-v15.0.zip',
        'CorePAS/Privileged Session Manager for SSH/PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.0.zip',
        'CorePAS/Vault/Vault Ansible Role-Rls-v15.0.zip')
    [IO.File]::WriteAllText((Join-Path $media 'license.xml'), '<license/>')
    [IO.File]::WriteAllText((Join-Path $media 'VC_redist.x86.exe'), 'x')
    $script:inventory = @(Get-PASMediaInventory -Path $media)
    $script:selection = Get-PASMediaSelection -Inventory $script:inventory
    $script:lab = @(@{Type = 'PVWA'; Name = 'PAS-PVWA'; Address = '192.0.2.33' }, @{Type = 'CPM'; Name = 'PAS-CPM'; Address = '192.0.2.34' },
        @{Type = 'PSM'; Name = 'PAS-PSM'; Address = '192.0.2.35' }, @{Type = 'PSMP'; Name = 'PAS-PSMP'; Address = '192.0.2.36' })
    function New-LabConfig([string]$Profile = 'Lab', [switch]$NoEula, [object[]]$Instances = $script:lab) {
        New-PASLabConfiguration -Environment MyPAM -VaultMode PrimaryDR -Instances $Instances -ControllerAddress 198.51.100.250 `
            -PrimaryAddress 192.0.2.31 -DRAddress 192.0.2.32 -Media $script:selection -SecurityProfile $Profile -AcceptEula:(-not $NoEula)
    }
}
AfterAll { $env:PAS_EASY_DATA_ROOT = $script:SavedDataRoot }

Describe 'UI backend contract' {
    It 'is satisfied by the PASeasyInstall module (Live) and by the Mock' {
        . (Join-Path $uiRoot 'Backend/Backend.Contract.ps1')
        { Assert-PASUIBackend } | Should -Not -Throw
        $mock = Import-Module (Join-Path $uiRoot 'Backend/Mock/PASeasyInstall.Mock.psd1') -PassThru -Force
        try {
            foreach ($name in (Get-PASUIBackendContract).Keys) {
                $cmd = Get-Command -Module PASeasyInstall.Mock -Name $name
                foreach ($p in (Get-PASUIBackendContract)[$name]) { $cmd.Parameters.ContainsKey($p) | Should -BeTrue -Because "$name -$p" }
            }
        } finally {
            Remove-Module $mock
            Import-PASTestModule
        }
    }
    It 'lists only public commands of the PASeasyInstall module' {
        . (Join-Path $uiRoot 'Backend/Backend.Contract.ps1')
        $public = @((Get-Command -Module PASeasyInstall).Name)
        foreach ($name in (Get-PASUIBackendContract).Keys) { $public | Should -Contain $name }
    }
    It 'stores non-ASCII PowerShell sources as UTF-8 with BOM (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        foreach ($f in @(Get-ChildItem -LiteralPath $PASModuleRoot, $uiRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') })) {
            $bytes = [IO.File]::ReadAllBytes($f.FullName)
            $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count -gt 0
            if ($nonAscii) {
                ($bytes.Length -ge 3 -and
                $bytes[0] -eq 0xEF -and
                $bytes[1] -eq 0xBB -and
                $bytes[2] -eq 0xBF) |
                    Should -BeTrue -Because $f.FullName
            }
        }
    }
    It 'defaults the desktop to the real installer and offers only Live and Mock' {
        foreach ($file in @((Join-Path $repo 'Start-PASeasyInstall.ps1'), (Join-Path $uiRoot 'App.ps1'), (Join-Path (Join-Path $PASModuleRoot 'Public') 'Start-PASeasyInstall.ps1'))) {
            $text = Get-Content -LiteralPath $file -Raw
            $text | Should -Match "ValidateSet\('Live', 'Mock'\)\]\[string\]\`$Backend = 'Live'" -Because $file
            $text | Should -Not -Match '\[switch\]\$Advanced|\$Theme\b' -Because $file
        }
    }
    It 'is part of the one module: Start-PASeasyInstall is exported and nothing else is required to import it' {
        $manifest = Import-PowerShellDataFile -Path $PASModuleManifest
        @($manifest.FunctionsToExport) | Should -Contain 'Start-PASeasyInstall'
        $manifest.ContainsKey('RequiredModules') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $repo 'PASeasyInstall.UI') | Should -BeFalse
    }
}

Describe 'Media inventory and selection' {
    It 'finds plain files and bundle entries without extracting, and drops bundle copies of plain files' {
        @($script:inventory | Where-Object { $_.Component -eq 'PVWA' }).Count | Should -Be 1
        @($script:inventory | Where-Object { $_.Component -eq 'PVWA' })[0].Entry | Should -BeNullOrEmpty
        @($script:inventory | Where-Object { $_.Component -eq 'CPM' })[0].Entry | Should -Match 'Central Policy Manager'
        @($script:inventory | Where-Object { $_.Component -eq 'PSMP' }).Count | Should -Be 2
        @($script:inventory | Where-Object { $_.Component -eq 'Prerequisite' }).Count | Should -Be 1
        @($script:inventory | Where-Object { $_.Name -match 'Ansible' }).Count | Should -Be 0
        @(Get-ChildItem (Join-Path $env:PAS_EASY_DATA_ROOT 'MediaCache') -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
    It 'recommends Ubuntu24 PSMP and the recovery key from the key archive' {
        $script:selection.PSMP.Variant | Should -Be 'Ubuntu24'
        $script:selection.RecoveryKey.Entry | Should -Be 'master/recpub.key'
        $script:selection.License.Name | Should -Be 'license.xml'
    }
}

Describe 'Deployment composition' {
    BeforeAll {
        $script:c = New-LabConfig
        $script:v = Test-PASLabConfiguration -Configuration $script:c
    }
    It 'composes one valid Primary + DR + four component configuration' {
        $script:v.Issues | Should -BeNullOrEmpty
        $script:v.Valid | Should -BeTrue
        @($script:c.components | ForEach-Object { $_.id }) | Should -Be @('vault', 'dr', 'pas-pvwa', 'pas-cpm', 'pas-psm', 'pas-psmp')
        @($script:c.components | ForEach-Object { $_.name })[2] | Should -Be 'PAS-PVWA'
        $script:c.execution.mode | Should -Be 'Sequential'
        $script:c.hosts['vault01'].user | Should -Be 'Administrator'
    }
    It 'extracts only selected bundle entries into the media cache, and only the public recovery key' {
        $cpm = @($script:c.components | Where-Object { $_.type -eq 'CPM' })[0]
        $cpm.media | Should -Match 'MediaCache'
        Test-Path -LiteralPath $cpm.media | Should -BeTrue
        $script:c.media.PublicRecoveryKey | Should -Match 'recpub\.key$'
        @(Get-ChildItem (Join-Path $env:PAS_EASY_DATA_ROOT 'MediaCache') -Recurse -File | Where-Object Name -eq 'recprv.key').Count |
            Should -Be 0
        $script:c.media.ServerZip | Should -Match 'Server-Rls-v15.0.zip$'
    }
    It 'records the lab deviations a template-built lab needs, and none in Secure' {
        $o = $script:c.security.overrides
        foreach ($k in 'WinRM.SkipCACheck', 'WinRM.SkipCNCheck', 'Vault.AllowRDP', 'CPM.AllowPinnedLeafTrust') { $o[$k] | Should -BeTrue }
        $secure = New-LabConfig -Profile Secure
        @($secure.security.overrides.Keys).Count | Should -Be 0
        @($secure.components | Where-Object { $_.type -eq 'CPM' })[0].options.Contains('pvwaTrustFrom') | Should -BeFalse
    }
    It 'wires PVWA lab certificate, CPM pinning and PSMP EULA and SSH identity' {
        $pvwa = @($script:c.components | Where-Object { $_.type -eq 'PVWA' })[0]
        $pvwa.options.createLabCertificate | Should -BeTrue
        $pvwa.options.pvwaUrl | Should -Be 'https://PAS-PVWA/PasswordVault'
        @($script:c.components | Where-Object { $_.type -eq 'CPM' })[0].options.pvwaTrustFrom | Should -Be 'pas-pvwa'
        @($script:c.components | Where-Object { $_.type -eq 'PSMP' })[0].options.acceptEula | Should -BeTrue
        $script:c.hosts['pas-psmp'].identityFile | Should -Match 'ssh.mypam.id_ed25519$'
    }
    It 'refuses PSMP without EULA acceptance' {
        $v = Test-PASLabConfiguration -Configuration (New-LabConfig -NoEula)
        $v.Valid | Should -BeFalse
        ($v.Issues -join ';') | Should -Match 'EULA'
    }
    It 'co-locates instances that share an address on one server named after the first' {
        $c = New-LabConfig -Instances @(@{
                Type = 'PVWA'
                Name = 'PVWA01'
                Address = '192.0.2.40'
            }, @{
                Type = 'CPM'
                Name = 'CPM01'
                Address = '192.0.2.40'
            })
        @($c.hosts.Keys) | Should -Contain 'pvwa01'
        @($c.hosts.Keys) | Should -Not -Contain 'cpm01'
        @($c.components | Where-Object { $_.type -eq 'CPM' })[0].host | Should -Be 'pvwa01'
    }
    It 'never reuses engine journal names as instance ids' {
        $c = New-LabConfig -Instances @(@{Type = 'PVWA'; Name = 'primary'; Address = '192.0.2.40' })
        @($c.components | Where-Object { $_.type -eq 'PVWA' })[0].id | Should -Not -Be 'primary'
    }
    It 'enriches plan items for the review' {
        $p = Get-PASLabPlan -Configuration $script:c
        $item = @($p.Items | Where-Object { $_.Type -eq 'PVWA' })[0]
        $item.Name |
            Should -Be 'PAS-PVWA'
        $item.Address |
            Should -Be '192.0.2.33'
        $item.Media |
            Should -Be 'Password Vault Web Access-Rls-v15.0.zip'
        @($p.Items | Where-Object { $_.Type -eq 'Vault' })[0].Media | Should -Be 'Server-Rls-v15.0.zip'
    }
    It 'saves and reloads to the same reviewed plan digest' {
        $path = Join-Path $TestDrive 'project.json'
        $saved = Export-PASLabConfiguration -Configuration $script:c -Path $path -Force
        $reloaded = Import-PASLabConfiguration -Path $saved
        (Get-PASLabPlan -Configuration $reloaded).ConfigDigest | Should -Be (Get-PASLabPlan -Configuration $script:c).ConfigDigest
    }
}

Describe 'Run preparation for a composed lab' {
    BeforeAll { $script:m = Get-Module PASeasyInstall }
    It 'turns a WinRM user into an explicit local account only for Windows servers' {
        $pw = ConvertTo-SecureString 'synthetic' -AsPlainText -Force
        $map = @{
            'pas-pvwa' = [pscredential]::new('Administrator', $pw)
            'pas-psmp' = [pscredential]::new('root', $pw)
            'vault01' = [pscredential]::new('LAB\admin', $pw)
        }
        $out = & $script:m { param(
                $c,
                $m
            ) ConvertTo-PASControllerCredentialMap $c $m } (Test-PASLabConfiguration -Configuration (New-LabConfig)).Configuration $map
        $out['pas-pvwa'].UserName | Should -Be '.\Administrator'
        $out['pas-psmp'].UserName | Should -Be 'root'
        $out['vault01'].UserName | Should -Be 'LAB\admin'
    }
    It 'plans the Vault first, then every component, CPM after its PVWA' {
        $p = Get-PASLabPlan -Configuration (New-LabConfig)
        @($p.Items | ForEach-Object { $_.Id }) | Should -Be @('vault', 'dr', 'pas-pvwa', 'pas-cpm', 'pas-psm', 'pas-psmp')
        @(@($p.Items | Where-Object { $_.Id -eq 'pas-cpm' })[0].DependsOn) | Should -Contain 'pas-pvwa'
    }
    It 'lists the credentials and secrets the wizard asks for' {
        $req = @(Get-PASCredentialRequirement -Configuration (New-LabConfig))
        @($req | Where-Object Kind -eq 'Credential' | ForEach-Object Key) |
            Should -Be @('vault01', 'dr01', 'pas-pvwa', 'pas-cpm', 'pas-psm', 'pas-psmp')
        @($req | Where-Object Kind -eq 'Secret' | ForEach-Object Key) | Should -Be @('VaultAdmin', 'VaultMaster', 'DRPassword')
    }
    It 'maps the Vault engine journal names onto the plan ids' {
        & $script:m { ConvertTo-PASComponentId 'primary_final' } | Should -Be 'vault'
        & $script:m { ConvertTo-PASComponentId 'dr_final' } | Should -Be 'dr'
        & $script:m { ConvertTo-PASComponentId 'pas-cpm' } | Should -Be 'pas-cpm'
    }
}

Describe 'Desktop model' {
    BeforeAll {
        . (Join-Path $uiRoot 'Model.ps1')
    }
    It 'needs five servers for the Full lab and puts CPM on the PVWA server' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'full'
        $slots = @(Get-PASUIServerSlots $state)
        @($slots | ForEach-Object { $_.Key }) -join ',' | Should -Be 'vault,dr,pvwa1,psm1,psmp1'
        ($slots | Where-Object { $_.Key -eq 'pvwa1' }).Roles | Should -Be 'PVWA + CPM'
        Set-PASUISlotValue $state 'pvwa1' 'Address' '192.0.2.21'
        $instances = @(Get-PASUIInstances $state)
        ($instances | Where-Object { $_.Type -eq 'CPM' }).Address | Should -Be '192.0.2.21'
        ($instances | Where-Object { $_.Type -eq 'CPM' }).Name | Should -Be 'CPM01'
        @($instances | Where-Object { $_.Type -in @('Vault', 'DRVault') }).Count | Should -Be 0
    }
    It 'gives a CPM its own server when there is no PVWA to share with' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'standard'
        $state.Counts.CPM = 2
        @(Get-PASUIServerSlots $state | ForEach-Object { $_.Key }) -join ',' | Should -Be 'vault,pvwa1,cpm2,psm1'
        $state.Colocate = $false
        @(Get-PASUIServerSlots $state | ForEach-Object { $_.Key }) -join ',' | Should -Be 'vault,pvwa1,cpm1,cpm2,psm1'
    }
    It 'says in plain words what is missing on the servers step' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'full'
        $issues = @(Get-PASUIInputIssues $state 'servers')
        ($issues -join ' ') | Should -Match 'Enter the address of the Vault server'
        ($issues -join ' ') | Should -Match 'Enter the lab password'
        ($issues -join ' ') | Should -Match 'license agreement'
        $number = 10
        foreach ($slot in Get-PASUIServerSlots $state) {
            $number++
            Set-PASUISlotValue $state $slot.Key 'Address' "192.0.2.$number"
        }
        $state.LabPassword = 'x'
        $state.AcceptEula = $true
        @(Get-PASUIInputIssues $state 'servers').Count | Should -Be 0
        Set-PASUISlotValue $state 'dr' 'Address' '192.0.2.11'
        (@(Get-PASUIInputIssues $state 'servers') -join ' ') | Should -Match 'used for two servers'
    }
    It 'counts finished steps per component and names the step to retry' {
        $snapshot = [pscustomobject]@{
            Status = 'Failed'
            Components = @(
                [pscustomobject]@{ Id = 'vault'; Type = 'Vault'; Status = 'Succeeded'; Message = '' }
                [pscustomobject]@{ Id = 'pvwa01'; Type = 'PVWA'; Status = 'Failed'; Message = 'boom' })
            Events = @(
                [pscustomobject]@{ Component = 'pvwa01'; Stage = 'install'; Event = 'TaskCompleted'; Status = 'Complete'; Message = '' }
                [pscustomobject]@{ Component = 'pvwa01'; Stage = 'install'; Event = 'TaskOutput'; Status = 'Info'; Message = 'late line' }
                [pscustomobject]@{ Component = 'pvwa01'; Stage = 'register'; Event = 'TaskFailed'; Status = 'Failed'; Message = 'ITATS937E limit' })
        }
        $progress = Get-PASUIRunProgress -Snapshot $snapshot -Catalog @{ Vault = 20; PVWA = 10 }
        $vault = $progress.Components | Where-Object { $_.Id -eq 'vault' }
        $vault.Done | Should -Be 20
        $pvwa = $progress.Components | Where-Object { $_.Id -eq 'pvwa01' }
        $pvwa.Done | Should -Be 1
        $pvwa.Current | Should -Be 'register'
        $pvwa.Kind | Should -Be 'bad'
        $progress.Percent | Should -Be 70
        (Get-PASUIFailure $snapshot).RetryStep | Should -Be 'pvwa01:register'
    }
    It 'takes one dropped folder as the media folder and adds dropped files to it' {
        $state = New-PASUIState
        Add-PASUIMediaDrop -State $state -Paths @('D:\Media') -IsFolder @($true)
        $state.MediaPath | Should -Be 'D:\Media'
        Add-PASUIMediaDrop -State $state -Paths @('D:\x\license.xml', 'D:\x\keys.zip') -IsFolder @($false, $false)
        @(Get-PASUIMediaPaths $state) -join '|' | Should -Be 'D:\Media|D:\x\license.xml|D:\x\keys.zip'
    }
    It 'writes the PowerShell equivalent without any password' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'starter'
        $state.LabPassword = 'SYNTHETIC_PASSWORD_642'
        $state.MediaPath = 'D:\Media'
        $text = Get-PASUICommandText $state
        $text | Should -Match 'New-PASLabConfiguration -Environment MyPAM -VaultMode Primary'
        $text | Should -Match 'Install-PASLab'
        $text | Should -Not -Match 'SYNTHETIC_PASSWORD_642'
    }
}

Describe 'Desktop screens' {
    BeforeAll {
        . (Join-Path $uiRoot 'Model.ps1')
        . (Join-Path $uiRoot 'Views.ps1')
    }
    It 'escapes everything that comes from the user or a server' {
        $state = New-PASUIState
        $state.LabName = '<script>alert(1)</script>'
        $state.Run = [pscustomobject]@{
            RunId = ('a' * 32); Name = '<b>lab</b>'; Status = 'Failed'; Message = '<i>m</i>'
            Components = @([pscustomobject]@{ Id = 'vault'; Type = 'Vault'; Status = 'Failed'; Message = '' })
            Events = @([pscustomobject]@{ TimestampUtc = '2026-11-21T10:00:00Z'; Component = 'vault'; Stage = 'install'; Event = 'TaskFailed'; Level = 'Error'; Status = 'Failed'; Message = '<img src=x>' })
        }
        $html = (Get-PASUIRunHtml $state @{ Vault = 3 }) + (Get-PASUILabHtml $state)
        $html | Should -Not -Match '<script>|<b>lab</b>|<img src=x>'
        $html | Should -Match '&lt;img src=x&gt;'
        $html | Should -Match 'id="act-retry"'
    }
    It 'shows the problems and no Install button when the plan is not valid' {
        $state = New-PASUIState
        $state.Check = @{ Valid = $false; Issues = @('Vault media file is Missing'); Warnings = @() }
        $html = Get-PASUIReviewHtml $state
        $html | Should -Match 'Vault media file is Missing'
        $html | Should -Not -Match 'act-install'
    }
    It 'keeps advanced settings out of the simple view' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'standard'
        Get-PASUIServersHtml $state | Should -Not -Match 'f-controller|f-separate'
        $state.Advanced = $true
        Get-PASUIServersHtml $state | Should -Match 'f-controller'
        Get-PASUIServersHtml $state | Should -Match 'f-separate'
    }
    It 'shows the step line only inside the four steps' {
        $state = New-PASUIState
        Get-PASUIStepsHtml $state | Should -BeNullOrEmpty
        $state.Screen = 'servers'
        $steps = Get-PASUIStepsHtml $state
        $steps | Should -Match 'step done.*step done.*step current'
        $steps | Should -Match 'id="step-review" class="step" disabled'
    }
}

Describe 'Desktop window (headless, simulated installation)' -Skip:(-not [bool](Get-Module -ListAvailable NativeHTMLKit)) {
    It 'walks from the start page to a finished and checked lab' {
        $out = Join-Path $TestDrive 'selftest.out'
        $err = Join-Path $TestDrive 'selftest.err'
        $saved = @{ Mode = $env:NATIVEHTMLKIT_TEST_MODE; Seconds = $env:PASUI_MOCK_STAGE_SECONDS }
        $env:NATIVEHTMLKIT_TEST_MODE = '1'
        $env:PASUI_MOCK_STAGE_SECONDS = '0.05'
        try {
            # Components are added to an existing Vault: the synthetic media has no real Vault installer.
            $scenario = Join-Path $TestDrive 'scenario.json'
            @{ media = $media; labName = 'SelfTest'; preset = 'custom'; existingVault = '192.0.2.5' } | ConvertTo-Json | Set-Content -LiteralPath $scenario -Encoding UTF8
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $uiRoot 'App.ps1') + '"'), '-Backend', 'Mock',
                '-StartDirectory', ('"' + $TestDrive + '"'), '-SelfTest', ('"' + $scenario + '"'))
            $process = Start-Process powershell.exe -ArgumentList $arguments -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
            if (-not $process.WaitForExit(240000)) {
                $process.Kill()
                throw 'The headless desktop did not finish within four minutes'
            }
        } finally {
            $env:NATIVEHTMLKIT_TEST_MODE = $saved.Mode
            $env:PASUI_MOCK_STAGE_SECONDS = $saved.Seconds
        }
        $text = (Get-Content -LiteralPath $out -Raw)
        $text | Should -Match 'SELFTEST failures=0' -Because ($text + (Get-Content -LiteralPath $err -Raw))
        $text | Should -Not -Match '(?m)^FAIL'
    }
}
