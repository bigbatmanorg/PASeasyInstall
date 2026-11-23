# The desktop window (PASeasyInstall\Desktop) and the public commands it calls. No server, no vendor
# execution: synthetic media in TestDrive. The screens are WPF controls: they are built here without showing
# a window and read back as text. One test starts the window process, one walks it with the simulated installer.
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
    # The screens: the shell of the window is read from Window.xaml but never shown. WPF needs an STA thread,
    # which Windows PowerShell 5.1 has by default.
    $script:CanDraw = ($env:OS -eq 'Windows_NT' -and [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA')
    . (Join-Path $uiRoot 'Model.ps1')
    if ($script:CanDraw) {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
        $script:window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $uiRoot 'Window.xaml')))
        $script:ui = @{}
        foreach ($name in @('Shell', 'Main', 'Steps', 'OptAdvanced', 'Notice', 'NoticeIcon', 'NoticeText', 'Bar', 'BtnBack', 'BtnNext',
                'NextBusy', 'NextText', 'NextArrow', 'BarText', 'Page', 'PageHost')) {
            $script:ui[$name] = $script:window.FindName($name)
        }
        $script:R = @{}
        $script:PasswordBoxes = @{}
        $script:Catalog = @{}
        $script:S = New-PASUIState
        . (Join-Path $uiRoot 'Controls.ps1')
        . (Join-Path $uiRoot 'Views.ps1')
    }
    function Get-TestPage {
        # Builds one screen for a state, as the window does, and returns its controls and its text.
        param([hashtable]$State, [string]$Screen)
        $script:S = $State
        $State.Screen = $Screen
        $script:R.Clear()
        $panel = New-Object Windows.Controls.StackPanel
        switch ($Screen) {
            'home' { Add-PASUIHomePage $panel }
            'media' { Add-PASUIMediaPage $panel }
            'lab' { Add-PASUILabPage $panel }
            'servers' { Add-PASUIServersPage $panel }
            'review' { Add-PASUIReviewPage $panel }
            'run' { Add-PASUIRunPage $panel }
        }
        return [pscustomobject]@{ Panel = $panel; Text = (Get-PASUIShownText $panel) }
    }
    function Test-PageControl {
        # Is there a control with this id on the page?
        param($Page, [string]$Id)
        return [bool](Find-PASUIControl $Page.Panel $Id)
    }
}
AfterAll {
    $env:PAS_EASY_DATA_ROOT = $script:SavedDataRoot
    if ($script:CanDraw) {
        Stop-PASUITasks
    }
}

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
        $script:c.execution.mode | Should -Be 'Parallel'
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
    It 'puts the HTML5 Gateway on the PSM for SSH server, or on a server of its own when asked' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'standard'
        $state.Counts.PSMP = 1
        $state.Counts['HTML5GW'] = 1
        @(Get-PASUIServerSlots $state | ForEach-Object { $_.Key }) -join ',' | Should -Be 'vault,pvwa1,psm1,psmp1'
        (Get-PASUIServerSlots $state | Where-Object { $_.Key -eq 'psmp1' }).Types -join ',' | Should -Be 'PSMP,HTML5GW'
        $state.ColocateGw = $false
        @(Get-PASUIServerSlots $state | ForEach-Object { $_.Key }) -join ',' | Should -Be 'vault,pvwa1,psm1,psmp1,gw1'
        (Get-PASUIServerSlots $state | Where-Object { $_.Key -eq 'psmp1' }).Types -join ',' | Should -Be 'PSMP'
        Set-PASUISlotValue $state 'psmp1' 'Address' '192.0.2.41'
        Set-PASUISlotValue $state 'gw1' 'Address' '192.0.2.42'
        $instances = @(Get-PASUIInstances $state)
        ($instances | Where-Object { $_.Type -eq 'PSMP' }).Address | Should -Be '192.0.2.41'
        ($instances | Where-Object { $_.Type -eq 'HTML5GW' }).Address | Should -Be '192.0.2.42'
    }
    It 'tells a check of finished steps and a server that gave up from an installation step' {
        $snapshot = [pscustomobject]@{
            Status = 'Running'
            Components = @(
                [pscustomobject]@{ Id = 'pvwa01'; Type = 'PVWA'; Status = 'Running'; Message = '' },
                [pscustomobject]@{ Id = 'psm01'; Type = 'PSM'; Status = 'Stopped'; Message = '' })
            Events = @(
                [pscustomobject]@{ Component = 'pvwa01'; Stage = 'extract'; Event = 'TaskRevalidated' },
                [pscustomobject]@{ Component = 'psm01'; Stage = 'register'; Event = 'VaultWaiting' },
                [pscustomobject]@{ Component = 'psm01'; Stage = ''; Event = 'LaneWaitingEnded' })
        }
        $rows = @((Get-PASUIRunProgress -Snapshot $snapshot).Components)
        ($rows | Where-Object { $_.Id -eq 'pvwa01' }).Checking | Should -BeTrue
        ($rows | Where-Object { $_.Id -eq 'pvwa01' }).GaveUp | Should -BeFalse
        ($rows | Where-Object { $_.Id -eq 'psm01' }).GaveUp | Should -BeTrue
        ($rows | Where-Object { $_.Id -eq 'psm01' }).Checking | Should -BeFalse
    }
    It 'says in plain words what is missing on the servers step' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'full'
        $issues = @(Get-PASUIInputIssues $state 'servers')
        ($issues -join ' ') | Should -Match 'Enter the address of the Vault server'
        ($issues -join ' ') | Should -Match 'Enter the Vault Master password'
        ($issues -join ' ') | Should -Match 'license agreement'
        $number = 10
        foreach ($slot in Get-PASUIServerSlots $state) {
            $number++
            Set-PASUISlotValue $state $slot.Key 'Address' "192.0.2.$number"
        }
        (@(Get-PASUIInputIssues $state 'servers') -join ' ') | Should -Match 'Enter the password of Administrator on the Vault server'
        (@(Get-PASUIInputIssues $state 'servers') -join ' ') | Should -Match 'Enter the password of root on the PSMP server'
        foreach ($slot in Get-PASUIServerSlots $state) {
            Set-PASUISlotValue $state $slot.Key 'Password' 'p'
        }
        foreach ($field in Get-PASUIVaultSecrets $state) {
            $state.Secrets[$field.Key] = 'Secret-1'
        }
        $state.Secrets.VaultMaster = 'has "quote'
        (@(Get-PASUIInputIssues $state 'servers') -join ' ') | Should -Match 'no double quote'
        $state.Secrets.VaultMaster = 'Secret-2'
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
    It 'reads the media from every folder and file that was added, and from the path that is typed' {
        $state = New-PASUIState
        Add-PASUIMediaSource -State $state -Paths @('D:\Media\', ' "D:\x\license.xml" ') | Should -Be 2
        Add-PASUIMediaSource -State $state -Paths @('D:\Media') | Should -Be 0
        $state.MediaPath = 'D:\x\keys.zip'
        @(Get-PASUIMediaPaths $state) -join '|' | Should -Be 'D:\Media|D:\x\license.xml|D:\x\keys.zip'
        $state.MediaScanned = $true
        Remove-PASUIMediaSource -State $state -Index 0
        @($state.MediaSources) -join '|' | Should -Be 'D:\x\license.xml'
        $state.MediaScanned | Should -BeFalse
    }
    It 'says for every found item in which added folder or file it lies' {
        $state = New-PASUIState
        $license = Join-Path $TestDrive 'elsewhere\license.xml'
        New-Item -ItemType Directory -Path (Split-Path $license -Parent) -Force | Out-Null
        [IO.File]::WriteAllText($license, '<license/>')
        $null = Add-PASUIMediaSource -State $state -Paths @($media, $license)
        $state.MediaItems = @(Get-PASMediaInventory -Path @($media, $license))
        $state.MediaSelection = Get-PASMediaSelection -Inventory $state.MediaItems
        $state.MediaScanned = $true
        $rows = @(Get-PASUIMediaRows $state)
        ($rows | Where-Object { $_.Kind -eq 'PVWA' }).Source | Should -Be $media
        # CPM lies inside the bundle ZIP of the media folder.
        ($rows | Where-Object { $_.Kind -eq 'CPM' }).Inside | Should -Match '\.zip$'
        ($rows | Where-Object { $_.Kind -eq 'CPM' }).Source | Should -Be $media
        $sources = @(Get-PASUIMediaSourceRows $state)
        $sources.Count | Should -Be 2
        $sources[0].Labels | Should -Contain 'PVWA'
        $sources[1].Count | Should -BeGreaterThan 0
        $sources[1].Labels -join ',' | Should -Match 'license'
        @($sources | Where-Object { $_.Missing }).Count | Should -Be 0
    }
    It 'marks an added path that does not exist' {
        $state = New-PASUIState
        $gone = Join-Path $TestDrive 'not-there'
        $null = Add-PASUIMediaSource -State $state -Paths @($gone)
        $state.MediaItems = @(Get-PASMediaInventory -Path @($gone))
        $state.MediaScanned = $true
        @(Get-PASUIMediaSourceRows $state)[0].Missing | Should -BeTrue
        @(Get-PASUIInputIssues $state 'media').Count | Should -Be 1
    }
    It 'keeps the choice of a server for CPM when another lab is picked' {
        $state = New-PASUIState
        $state.Colocate = $false
        Set-PASUIPreset $state 'full'
        $state.Colocate | Should -BeFalse
        @(Get-PASUIServerSlots $state | Where-Object { $_.Key -eq 'cpm1' }).Count | Should -Be 1
        Set-PASUIPreset $state 'starter'
        @(Get-PASUIServerSlots $state | ForEach-Object { $_.Key }) -join ',' | Should -Be 'vault,pvwa1,cpm1'
    }
    It 'estimates a lab whose servers are installed at the same time' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'full'
        # Measured on 22 November 2026: 23 minutes.
        Get-PASUIEstimateMinutes $state | Should -BeIn (20..26)
        $state.Domain = 'New'
        Set-PASUIPreset $state 'standard'
        Get-PASUIEstimateMinutes $state | Should -BeIn (18..24)
    }
    It 'adds -SkipHardening to the PowerShell equivalent only when hardening is switched off' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'starter'
        $state.MediaPath = 'D:\Media'
        Get-PASUICommandText $state | Should -Not -Match 'SkipHardening'
        $state.Hardening = $false
        Get-PASUICommandText $state | Should -Match '-SecurityProfile Lab -SkipHardening'
    }
    It 'writes the PowerShell equivalent without any password' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'starter'
        Set-PASUISlotValue $state 'vault' 'Password' 'SYNTHETIC_PASSWORD_642'
        $state.Secrets.VaultAdmin = 'SYNTHETIC_PASSWORD_642'
        $state.MediaPath = 'D:\Media'
        $text = Get-PASUICommandText $state
        $text | Should -Match 'New-PASLabConfiguration -Environment MyPAM -VaultMode Primary'
        $text | Should -Match 'Install-PASLab'
        $text | Should -Not -Match 'SYNTHETIC_PASSWORD_642'
    }
}

Describe 'Desktop screens' {
    It 'shows what comes from the user or a server as plain text, and offers to try a failed step again' {
        $state = New-PASUIState
        $state.LabName = '<script>alert(1)</script>'
        $state.Run = [pscustomobject]@{
            RunId = ('a' * 32); Name = '<b>lab</b>'; Status = 'Failed'; Message = '<i>m</i>'
            Components = @([pscustomobject]@{ Id = 'vault'; Type = 'Vault'; Status = 'Failed'; Message = '' })
            Events = @([pscustomobject]@{ TimestampUtc = '2026-11-21T10:00:00Z'; Component = 'vault'; Stage = 'install'; Event = 'TaskFailed'; Level = 'Error'; Status = 'Failed'; Message = '<img src=x>' })
        }
        $page = Get-TestPage $state 'run'
        $page.Text | Should -Match ([regex]::Escape('<b>lab</b>'))
        $page.Text | Should -Match ([regex]::Escape('<img src=x>'))
        $page.Text | Should -Match 'The installation stopped'
        Test-PageControl $page 'act-retry' | Should -BeTrue
        Test-PageControl $page 'act-health' | Should -BeFalse
        (Get-TestPage $state 'lab').Text | Should -Match 'What do you want to build'
    }
    It 'shows the problems and no Install button when the plan is not valid' {
        $state = New-PASUIState
        $state.Check = @{ Valid = $false; Issues = @('Vault media file is Missing'); Warnings = @() }
        $page = Get-TestPage $state 'review'
        $page.Text | Should -Match 'Vault media file is Missing'
        Test-PageControl $page 'act-install' | Should -BeFalse
    }
    It 'keeps advanced settings out of the simple view' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'standard'
        Test-PageControl (Get-TestPage $state 'servers') 'f-controller' | Should -BeFalse
        $state.Advanced = $true
        Test-PageControl (Get-TestPage $state 'servers') 'f-controller' | Should -BeTrue
    }
    It 'shows the step line only inside the four steps' {
        $script:S = New-PASUIState
        Show-PASUISteps
        $script:ui.Steps.Children.Count | Should -Be 0
        $script:S.Screen = 'servers'
        Show-PASUISteps
        $steps = @($script:ui.Steps.Children | Where-Object { $_ -is [Windows.Controls.Button] })
        ($steps | ForEach-Object { [string]$_.Tag }) -join ',' | Should -Be 'step-media,step-lab,step-servers,step-review'
        # Finished steps can be pressed; the current one and the ones ahead cannot.
        ($steps | ForEach-Object { [string]$_.IsEnabled }) -join ',' | Should -Be 'True,True,False,False'
    }
    It 'lists the installations of this computer on the start page' {
        $state = New-PASUIState
        $state.Runs = @([pscustomobject]@{ RunId = ('b' * 32); Name = 'Lab01'; Status = 'Succeeded'; StartedUtc = '2026-11-21T10:00:00Z' })
        $page = Get-TestPage $state 'home'
        $page.Text | Should -Match 'Build a CyberArk PAM lab'
        $page.Text | Should -Match 'Lab01'
        Test-PageControl $page ('run-' + ('b' * 32)) | Should -BeTrue
    }
}

Describe 'Desktop window (simulated installation)' -Skip:($env:OS -ne 'Windows_NT') {
    It 'Start-PASeasyInstall opens the window in its own process and returns at once' {
        # The window process starts and waits. It is found by its start folder and stopped.
        $folder = Join-Path $TestDrive 'start-here'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $saved = @{ Root = $env:PAS_EASY_DATA_ROOT }
        $env:PAS_EASY_DATA_ROOT = Join-Path $TestDrive 'start-data'
        Push-Location $folder
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            Start-PASeasyInstall -Backend Mock
            $watch.Elapsed.TotalSeconds | Should -BeLessThan 30
            $mine = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { [string]$_.CommandLine -like "*Desktop\App.ps1*" -and [string]$_.CommandLine -like "*start-here*" })
            $mine.Count | Should -BeGreaterThan 0
            (Get-Content -LiteralPath (Join-Path $env:PAS_EASY_DATA_ROOT 'desktop.err.log') -Raw -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        } finally {
            Pop-Location
            Get-CimInstance Win32_Process | Where-Object { [string]$_.CommandLine -like "*start-here*" -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            $env:PAS_EASY_DATA_ROOT = $saved.Root
        }
    }
    It 'walks from the start page to a finished and checked lab' {
        $out = Join-Path $TestDrive 'selftest.out'
        $err = Join-Path $TestDrive 'selftest.err'
        $saved = @{ Seconds = $env:PASUI_MOCK_STAGE_SECONDS }
        $env:PASUI_MOCK_STAGE_SECONDS = '0.05'
        try {
            # Components are added to an existing Vault: the synthetic media has no real Vault installer.
            $scenario = Join-Path $TestDrive 'scenario.json'
            # It walks every screen: the Advanced view, the confirmation, the installation page and, because the
            # window is told to forget the accounts, the accounts dialog before the lab check.
            # The media is added by its path; a second folder is added and removed again; the lab is installed
            # without the vendor hardening, which the review step and the confirmation must say.
            $extra = Join-Path $TestDrive 'extra-media'
            New-TestZip (Join-Path $extra 'PTA-Installer-Rls-v15.2.2.zip') @('pta_installer.sh')
            @{ media = $media; removedMedia = $extra; labName = 'SelfTest'; preset = 'custom'; existingVault = '192.0.2.5'; advanced = $true; hardening = $false; forgetAccounts = $true } |
                ConvertTo-Json | Set-Content -LiteralPath $scenario -Encoding UTF8
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $uiRoot 'App.ps1') + '"'), '-Backend', 'Mock',
                '-StartDirectory', ('"' + $TestDrive + '"'), '-SelfTest', ('"' + $scenario + '"'))
            $process = Start-Process powershell.exe -ArgumentList $arguments -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -WindowStyle Hidden
            if (-not $process.WaitForExit(240000)) {
                $process.Kill()
                throw 'The window did not finish its walk within four minutes'
            }
        } finally {
            $env:PASUI_MOCK_STAGE_SECONDS = $saved.Seconds
        }
        $text = (Get-Content -LiteralPath $out -Raw)
        $text | Should -Match 'SELFTEST failures=0' -Because ($text + (Get-Content -LiteralPath $err -Raw))
        $text | Should -Not -Match '(?m)^FAIL'
    }
}

Describe 'Servers form and server check' {
    It 'asks for an account and a password per server and for the Vault passwords, not for one lab password' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'full'
        $page = Get-TestPage $state 'servers'
        foreach ($id in 'srv-vault-user', 'srv-vault-pass', 'srv-dr-pass', 'srv-pvwa1-user', 'srv-psmp1-pass', 'sec-VaultAdmin', 'sec-VaultMaster', 'sec-DRPassword') {
            Test-PageControl $page $id | Should -BeTrue -Because $id
        }
        (Find-PASUIControl $page.Panel 'srv-psmp1-user').Text | Should -Be 'root'
        (Find-PASUIControl $page.Panel 'srv-vault-user').Text | Should -Be 'Administrator'
        (Find-PASUIControl $page.Panel 'srv-vault-pass') | Should -BeOfType ([Windows.Controls.PasswordBox])
        $page.Text | Should -Not -Match 'Lab password'
        $state.VaultMode = 'Existing'
        @(Get-PASUIVaultSecrets $state | ForEach-Object { $_.Key }) | Should -Be @('VaultAdmin')
    }
    It 'hands the account of each server to the configuration' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'standard'
        Set-PASUISlotValue $state 'psm1' 'User' 'labadmin'
        (Get-PASUIInstances $state | Where-Object { $_.Type -eq 'PSM' }).Username | Should -Be 'labadmin'
        (Get-PASUIInstances $state | Where-Object { $_.Type -eq 'PVWA' }).Username | Should -Be 'Administrator'
    }
    It 'shows every problem of the server check in words and never the typed passwords' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'starter'
        $state.Preflight = @(
            [pscustomobject]@{ Server = 'vault01'; Address = '192.0.2.11'; Check = 'TCP port 5986'; Passed = $false; Detail = 'WinRM HTTPS port 5986 did not answer within 4 seconds.' }
            [pscustomobject]@{ Server = 'pvwa01'; Address = '192.0.2.12'; Check = 'TCP port 5986'; Passed = $true; Detail = 'answers' })
        $page = Get-TestPage $state 'servers'
        # A password is typed into its box: the model only learns that there is one, the page never shows it.
        (Find-PASUIControl $page.Panel 'srv-vault-pass').Password = 'SYNTHETIC_PASSWORD_642'
        $state.Slots['vault']['Password'] | Should -Be 'set'
        $state.Advanced = $true
        $page = Get-TestPage $state 'servers'
        $page.Text | Should -Match 'The servers are not ready'
        $page.Text | Should -Match '192\.0\.2\.11 vault01'
        $page.Text | Should -Match 'did not answer within 4 seconds'
        $page.Text | Should -Not -Match 'SYNTHETIC_PASSWORD_642'
        ($state | ConvertTo-Json -Depth 6 -WarningAction SilentlyContinue) | Should -Not -Match 'SYNTHETIC_PASSWORD_642'
        $state.Checking = $true
        Show-PASUIBar
        $script:ui.BtnNext.IsEnabled | Should -BeFalse
        $script:ui.NextText.Text | Should -Be 'Checking...'
        (Find-PASUIControl $page.Panel 'srv-vault-pass').Clear()
    }
    It 'says which part of the server check is running' {
        $state = New-PASUIState
        $state.Configuration = @{ hosts = [ordered]@{ a = @{}; b = @{}; c = @{} } }
        $state.Checking = $true
        $state.CheckPhase = 'reach'
        Set-PASUIPreset $state 'starter'
        (Get-TestPage $state 'servers').Text | Should -Match 'part 1 of 2.*the 3 servers answer'
        $state.CheckPhase = 'signin'
        (Get-TestPage $state 'servers').Text | Should -Match 'part 2 of 2.*signing in to the 3 servers'
    }
    It 'counts a step, its restart and its continuation as one step' {
        $events = @()
        foreach ($stage in 'management', 'media-upload', 'preflight', 'extract', 'prerequisites', 'prerequisites-reboot', 'prerequisites-pass2', 'prerequisites-pass2-reboot', 'install') {
            $events += [pscustomobject]@{ Component = 'psm'; Stage = $stage; Event = 'TaskStarted' }
            $events += [pscustomobject]@{ Component = 'psm'; Stage = $stage; Event = 'TaskCompleted' }
        }
        $events += [pscustomobject]@{ Component = 'psm'; Stage = 'install-reboot'; Event = 'TaskStarted' }
        $snapshot = [pscustomobject]@{ Status = 'Running'; Events = $events; Components = @([pscustomobject]@{ Id = 'psm'; Type = 'PSM'; Status = 'Running'; Message = '' }) }
        $row = (Get-PASUIRunProgress -Snapshot $snapshot -Catalog @{ PSM = 10 }).Components[0]
        $row.Total | Should -Be 10
        $row.Done | Should -Be 5
        $row.Current | Should -Be 'install-reboot'
        Get-PASUIStageText 'install-pass2' | Should -Match 'continued after the restart'
        # A step whose own name ends in -reboot stays a step of its own.
        Get-PASUIStepOfStage 'hardening-reboot' @('harden-primary', 'hardening-reboot') | Should -Be 'hardening-reboot'
    }
    It 'keeps the number of steps of a component from the start to the end' {
        $names = @('media-upload', 'preflight', 'install', 'register', 'verify')
        $events = @(
            [pscustomobject]@{ Component = 'cpm'; Stage = 'LocalPreflight'; Event = 'TaskCompleted' }
            [pscustomobject]@{ Component = 'cpm'; Stage = 'pvwa-trust-certificate'; Event = 'TaskCompleted' }
            [pscustomobject]@{ Component = 'cpm'; Stage = 'media-upload'; Event = 'TaskCompleted' }
            [pscustomobject]@{ Component = 'cpm'; Stage = 'preflight'; Event = 'TaskStarted' })
        $components = @(
            [pscustomobject]@{ Id = 'cpm'; Type = 'CPM'; Status = 'Running'; Message = '' }
            [pscustomobject]@{ Id = 'join-web'; Type = 'DomainJoin'; Status = 'Pending'; Message = '' })
        $snapshot = [pscustomobject]@{ Status = 'Running'; Events = $events; Components = $components }
        $catalog = @{ CPM = $names; DomainJoin = @('dns', 'join', 'reboot', 'local-admin', 'verify') }
        $progress = Get-PASUIRunProgress -Snapshot $snapshot -Catalog $catalog
        $progress.Components[0].Done | Should -Be 1
        $progress.Components[0].Total | Should -Be 5
        $progress.Components[1].Total | Should -Be 5
        $progress.Total | Should -Be 10
    }
    It 'says that a component waits for its turn at the Vault' {
        $events = @(
            [pscustomobject]@{ Component = 'psm'; Stage = 'install'; Event = 'TaskCompleted' }
            [pscustomobject]@{ Component = 'psm'; Stage = 'register'; Event = 'VaultWaiting' }
            [pscustomobject]@{ Component = 'pta'; Stage = ''; Event = 'ComponentWaiting' })
        $components = @(
            [pscustomobject]@{ Id = 'psm'; Type = 'PSM'; Status = 'Running'; Message = '' }
            [pscustomobject]@{ Id = 'pta'; Type = 'PTA'; Status = 'Pending'; Message = '' })
        $snapshot = [pscustomobject]@{ Status = 'Running'; Events = $events; Components = $components }
        $rows = (Get-PASUIRunProgress -Snapshot $snapshot -Catalog @{ PSM = 10; PTA = 7 }).Components
        $rows[0].Waiting | Should -Match 'turn at the Vault'
        $rows[1].Waiting | Should -Be 'Waiting for PVWA'
        $state = New-PASUIState
        $state.Run = $snapshot
        $script:Catalog = @{ PSM = 10; PTA = 7 }
        $text = (Get-TestPage $state 'run').Text
        $script:Catalog = @{}
        $text | Should -Match 'Waiting for its turn at the Vault'
        $text | Should -Match 'Waiting for PVWA'
    }
    It 'offers the Advanced switch only on a page that has something more to show' {
        $state = New-PASUIState
        foreach ($screen in 'home', 'media') {
            $state.Screen = $screen
            Test-PASUIAdvancedApplies $state | Should -BeFalse
        }
        foreach ($screen in 'servers', 'review', 'run') {
            $state.Screen = $screen
            Test-PASUIAdvancedApplies $state | Should -BeTrue
        }
        $state.Screen = 'lab'
        $state.Preset = 'standard'
        Test-PASUIAdvancedApplies $state | Should -BeFalse
        $state.Preset = 'custom'
        Test-PASUIAdvancedApplies $state | Should -BeTrue
    }
}

Describe 'Fast reachability check before an installation' {
    It 'names the servers that do not answer, within seconds, and starts nothing' {
        $cfg = New-PASLabConfiguration -Environment Unreachable -VaultMode Existing -ExistingVaultAddress 192.0.2.5 -ControllerAddress 198.51.100.250 `
            -Media $script:selection -SecurityProfile Lab -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.33' })
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $problems = @(& (Get-Module -Name PASeasyInstall) { param($c) Get-PASUnreachableServer -Configuration $c -TimeoutSeconds 2 } $cfg)
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 10
        $problems.Count | Should -Be 1
        $problems[0] | Should -Match '192\.0\.2\.33 \(pvwa01\): no answer on WinRM HTTPS port 5986'
        { & (Get-Module -Name PASeasyInstall) { param($c) Assert-PASServersReachable -Configuration $c } $cfg } | Should -Throw '*Nothing was started*192.0.2.33*'
        $rows = @(Test-PASPreflight -Configuration $cfg -ConnectivityOnly)
        @($rows | Where-Object { $_.Check -like 'TCP port*' -and -not $_.Passed }).Count | Should -Be 1
        @($rows | Where-Object { $_.Check -like '*session*' -or $_.Check -like '*sign-in*' }).Count | Should -Be 0
    }
}

Describe 'Server check of a Linux server before its SSH key exists' {
    BeforeAll {
        $script:linuxCfg = New-PASLabConfiguration -Environment LinuxCheck -VaultMode Existing -ExistingVaultAddress 192.0.2.5 -ControllerAddress 198.51.100.250 `
            -Media $script:selection -SecurityProfile Lab -AcceptEula -Instances @(@{ Type = 'PSMP'; Name = 'PSMP01'; Address = '192.0.2.36' })
        $script:linuxPassword = ConvertTo-SecureString 'SYNTHETIC_PASSWORD_731' -AsPlainText -Force
        Mock -ModuleName PASeasyInstall Test-PASTcpPort { $true }
        # ssh-keygen -F: the server is not in a known_hosts file yet.
        Mock -ModuleName PASeasyInstall Invoke-PASNativeQuiet { @{ ExitCode = 1; Output = '' } }
    }
    It 'reports a wrong root password' {
        Mock -ModuleName PASeasyInstall Invoke-PASSshWithPassword { @{ ExitCode = 255; Output = 'root@192.0.2.36: Permission denied (publickey,password).' } }
        $rows = @(Test-PASPreflight -Configuration $script:linuxCfg -LabPassword $script:linuxPassword)
        $row = @($rows | Where-Object { $_.Check -eq 'SSH password sign-in' })
        $row.Count | Should -Be 1
        $row[0].Passed | Should -Be $false
        $row[0].Detail | Should -Match 'Password sign-in as root failed.*Permission denied'
        ($rows | Out-String) | Should -Not -Match 'SYNTHETIC_PASSWORD_731'
    }
    It 'passes with the right password, reads account and distribution, and authorises no key' {
        Mock -ModuleName PASeasyInstall Invoke-PASSshWithPassword { @{ ExitCode = 0; Output = "0`nID=ubuntu`nVERSION_ID=`"24.04`"`nPRETTY_NAME=`"Ubuntu 24.04 LTS`"" } }
        $rows = @(Test-PASPreflight -Configuration $script:linuxCfg -LabPassword $script:linuxPassword)
        @($rows | Where-Object { $_.Check -in @('SSH password sign-in', 'Root account', 'Operating system') -and $_.Passed -eq $true }).Count | Should -Be 3
        Should -Invoke -ModuleName PASeasyInstall Invoke-PASSshWithPassword -Times 1 -Exactly -ParameterFilter {
            $Arguments[-1] -eq 'id -u; cat /etc/os-release' -and ($Arguments -join ' ') -notmatch 'authorized_keys'
        }
    }
    It 'says "not checked" when no password was given' {
        Mock -ModuleName PASeasyInstall Invoke-PASSshWithPassword { throw 'must not be called' }
        $rows = @(Test-PASPreflight -Configuration $script:linuxCfg)
        $row = @($rows | Where-Object { $_.Check -eq 'SSH password sign-in' })
        $row.Count | Should -Be 1
        $row[0].Passed | Should -BeNullOrEmpty
    }
}

Describe '"Who installs": user and company name for the vendor installers' {
    It 'is optional, is kept in the configuration and reaches every Windows component' {
        $plain = New-LabConfig
        $plain.options.Contains('installerName') | Should -BeFalse
        $cfg = New-PASLabConfiguration -Environment WhoLab -VaultMode Existing -ExistingVaultAddress 192.0.2.5 -Media $script:selection -SecurityProfile Lab `
            -InstallerName ' Lab Admin ' -InstallerCompany 'Example & Co. (Lab)' -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.33' })
        $cfg.options.installerName | Should -Be 'Lab Admin'
        $cfg.options.installerCompany | Should -Be 'Example & Co. (Lab)'
        (Test-PASLabConfiguration -Configuration $cfg).Valid | Should -BeTrue
        $inventory = & (Get-Module -Name PASeasyInstall) { param($c) New-PASRuntimeInventory -Config $c -CredentialMap @{} -SkipMediaHash } $cfg
        $inventory.Values.Components['pvwa01'].InstallerName | Should -Be 'Lab Admin'
        $inventory.Values.Components['pvwa01'].InstallerCompany | Should -Be 'Example & Co. (Lab)'
    }
    It 'refuses characters that do not belong into an installer answer file' {
        $cfg = New-PASLabConfiguration -Environment WhoLab -VaultMode Existing -ExistingVaultAddress 192.0.2.5 -Media $script:selection -SecurityProfile Lab `
            -InstallerName "Lab`"Admin" -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.33' })
        $check = Test-PASLabConfiguration -Configuration $cfg
        $check.Valid | Should -BeFalse
        ($check.Issues -join ' ') | Should -Match 'options\.installerName'
    }
    It 'has a field pair in the Advanced view of the Servers step' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'starter'
        Test-PageControl (Get-TestPage $state 'servers') 'f-installer-name' | Should -BeFalse
        $state.Advanced = $true
        $state.InstallerCompany = 'Example Corp'
        $page = Get-TestPage $state 'servers'
        Test-PageControl $page 'f-installer-name' | Should -BeTrue
        (Find-PASUIControl $page.Panel 'f-installer-company').Text | Should -Be 'Example Corp'
    }
}

Describe 'A lab with an Active Directory domain' {
    It 'creates a new forest and joins the PVWA, CPM and PSM servers, never the Vault or the Linux server' {
        $cfg = New-PASLabConfiguration -Environment DomLab -VaultMode Primary -PrimaryAddress 192.0.2.31 -ControllerAddress 198.51.100.250 `
            -Media $script:selection -SecurityProfile Lab -AcceptEula -Instances $script:lab `
            -DomainMode New -DomainName pam.lab -DomainControllerAddress 192.0.2.40
        $cfg.activeDirectory.mode | Should -Be 'Create'
        $cfg.activeDirectory.domain | Should -Be 'pam.lab'
        $cfg.activeDirectory.joinUser | Should -Be 'PAM\Administrator'
        $cfg.hosts['dc01'].address | Should -Be '192.0.2.40'
        @($cfg.activeDirectory.join).Count | Should -Be 3
        @($cfg.activeDirectory.join) | Should -Not -Contain 'vault01'
        @($cfg.activeDirectory.join | Where-Object { $cfg.hosts[$_].os -ne 'Windows' }).Count | Should -Be 0
        $check = Test-PASLabConfiguration -Configuration $cfg
        $check.Issues | Should -BeNullOrEmpty
        $plan = Get-PASLabPlan -Configuration $cfg
        $plan.Items[0].Type | Should -Be 'AD'
        @($plan.DomainJoins).Count | Should -Be 3
        $keys = @(Get-PASCredentialRequirement -Configuration $cfg | ForEach-Object { $_.Key })
        foreach ($key in @('dc01', 'ADSafeMode', 'DomainJoinPassword', 'PSMDomainInstaller')) {
            $keys | Should -Contain $key
        }
    }
    It 'uses an existing domain through one of its DNS servers' {
        $instances = @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.33' })
        $cfg = New-PASLabConfiguration -Environment DomLab -VaultMode Existing -ExistingVaultAddress 192.0.2.5 -Media $script:selection -SecurityProfile Lab `
            -Instances $instances -DomainMode Existing -DomainName corp.example -DomainControllerAddress 192.0.2.40 -DomainUsername 'CORP\joiner'
        $cfg.activeDirectory.mode | Should -Be 'Existing'
        $cfg.activeDirectory.joinUser | Should -Be 'CORP\joiner'
        @($cfg.activeDirectory.dnsServers) | Should -Be @('192.0.2.40')
        @($cfg.components | Where-Object { $_.type -eq 'AD' }).Count | Should -Be 0
        (Test-PASLabConfiguration -Configuration $cfg).Issues | Should -BeNullOrEmpty
        $missing = New-PASLabConfiguration -Environment DomLab -VaultMode Existing -ExistingVaultAddress 192.0.2.5 -Media $script:selection -SecurityProfile Lab `
            -Instances $instances -DomainMode Existing -DomainName corp.example
        ((Test-PASLabConfiguration -Configuration $missing).Issues -join ' ') | Should -Match 'DNS servers'
    }
    It 'leaves a lab without a domain as it was' {
        $cfg = New-LabConfig
        $cfg.activeDirectory.mode | Should -Be 'None'
        @($cfg.activeDirectory.join).Count | Should -Be 0
    }
}

Describe 'Desktop: a lab with a domain' {
    It 'adds one server line for a new domain and none without a domain' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'standard'
        $before = @(Get-PASUIServerSlots $state).Count
        $page = Get-TestPage $state 'lab'
        Test-PageControl $page 'domain-New' | Should -BeTrue
        Test-PageControl $page 'f-domainname' | Should -BeFalse
        $state.Domain = 'New'
        $slots = @(Get-PASUIServerSlots $state)
        $slots.Count | Should -Be ($before + 1)
        $slots[0].Key | Should -Be 'dc'
        @(Get-PASUIInstances $state | Where-Object { $_.Type -eq 'AD' }).Count | Should -Be 0
        (Find-PASUIControl (Get-TestPage $state 'lab').Panel 'f-domainname').Text | Should -Be 'pam.lab'
        $page = Get-TestPage $state 'servers'
        Test-PageControl $page 'srv-dc-addr' | Should -BeTrue
        $page.Text | Should -Match 'restore mode password'
        Get-PASUICommandText $state | Should -Match '-DomainMode New -DomainName pam\.lab'
    }
    It 'asks for the domain name and offers a line for an existing domain' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'standard'
        $state.Domain = 'Existing'
        $state.DomainName = 'nodots'
        (Get-PASUIInputIssues $state 'lab') -join ' ' | Should -Match 'DNS name of the domain'
        $state.DomainName = 'corp.example'
        (Get-PASUIInputIssues $state 'lab') -join ' ' | Should -Not -Match 'DNS name of the domain'
        Test-PageControl (Get-TestPage $state 'servers') 'srv-domain-addr' | Should -BeTrue
        (Get-PASUIInputIssues $state 'servers') -join ' ' | Should -Match 'address of the Existing domain'
    }
}

Describe 'HTML5 Gateway' {
    BeforeAll {
        $gatewayMedia = Join-Path $TestDrive 'gw-media'
        New-TestZip (Join-Path $gatewayMedia 'HTML5 Gateway-Rls-15.0.zip') @('HTML5 Gateway-Rls-15.0/PSMGWDocker/html5_console.sh')
        $script:gatewayInventory = @($script:inventory) + @(Get-PASMediaInventory -Path $gatewayMedia)
        $script:gatewaySelection = Get-PASMediaSelection -Inventory $script:gatewayInventory
        $script:gatewayLab = @(@{ Type = 'PVWA'; Name = 'PAS-PVWA'; Address = '192.0.2.33' }, @{ Type = 'PSM'; Name = 'PAS-PSM'; Address = '192.0.2.35' },
            @{ Type = 'PSMP'; Name = 'pas-psmp'; Address = '192.0.2.36' }, @{ Type = 'HTML5GW'; Name = 'pas-psmp'; Address = '192.0.2.36' })
    }
    It 'is found in the media folder, with a version also without the letter v' {
        $item = @($script:gatewayInventory | Where-Object Component -eq 'HTML5GW')
        $item.Count | Should -Be 1
        $item[0].Version | Should -Be '15.0'
        $script:gatewaySelection.ContainsKey('HTML5GW') | Should -BeTrue
    }
    It 'shares the PSMP server, comes after PVWA and PSM, and trusts the lab PVWA' {
        $cfg = New-PASLabConfiguration -Environment GwLab -VaultMode Primary -PrimaryAddress 192.0.2.31 -ControllerAddress 198.51.100.250 `
            -Media $script:gatewaySelection -SecurityProfile Lab -AcceptEula -Instances $script:gatewayLab
        (Test-PASLabConfiguration -Configuration $cfg).Issues | Should -BeNullOrEmpty
        $gateway = @($cfg.components | Where-Object type -eq 'HTML5GW')[0]
        $psmp = @($cfg.components | Where-Object type -eq 'PSMP')[0]
        $gateway.host | Should -Be $psmp.host
        $gateway.options.pvwaTrustFrom | Should -Be 'pas-pvwa'
        [string]$cfg.options.pacliPackage | Should -Match 'PACLI-Rls'
        $plan = Get-PASLabPlan -Configuration $cfg
        $plan.Items[-1].Type | Should -Be 'HTML5GW'
        $plan.Items[-1].DependsOn | Should -Contain 'pas-pvwa'
        $plan.Items[-1].DependsOn | Should -Contain 'pas-psm'
        @(Get-PASStageCatalog -Component HTML5GW | ForEach-Object Stage) | Should -Be @('media-upload', 'preflight', 'extract', 'prerequisites', 'install', 'verify')
    }
    It 'needs the license agreement and a PVWA in the same lab' {
        $noEula = New-PASLabConfiguration -Environment GwLab -VaultMode Primary -PrimaryAddress 192.0.2.31 -ControllerAddress 198.51.100.250 `
            -Media $script:gatewaySelection -SecurityProfile Lab -Instances @($script:gatewayLab | Where-Object { $_.Type -ne 'PSMP' })
        ((Test-PASLabConfiguration -Configuration $noEula).Issues -join ' ') | Should -Match 'license agreement.*HTML5 Gateway'
        $noPvwa = New-PASLabConfiguration -Environment GwLab -VaultMode Existing -ExistingVaultAddress 192.0.2.5 -Media $script:gatewaySelection -SecurityProfile Lab -AcceptEula `
            -Instances @(@{ Type = 'HTML5GW'; Name = 'gw01'; Address = '192.0.2.36' })
        ((Test-PASLabConfiguration -Configuration $noPvwa).Issues -join ' ') | Should -Match 'needs a PVWA in the same lab'
    }
    It 'is one more component in the window, on the PSMP server when there is one' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'full'
        $state.Counts['HTML5GW'] = 1
        $slots = @(Get-PASUIServerSlots $state)
        @($slots | Where-Object { $_.Types -contains 'HTML5GW' }).Count | Should -Be 1
        ($slots | Where-Object { $_.Types -contains 'HTML5GW' }).Roles | Should -Be 'PSMP + HTML5 Gateway'
        @(Get-PASUIInstances $state | Where-Object Type -eq 'HTML5GW').Count | Should -Be 1
        $state.Counts.PSMP = 0
        (@(Get-PASUIServerSlots $state) | Where-Object { $_.Types -contains 'HTML5GW' }).Roles | Should -Be 'HTML5 Gateway'
        Test-PageControl (Get-TestPage $state 'lab') 'cnt-HTML5GW-inc' | Should -BeFalse
        $state.Preset = 'custom'
        Test-PageControl (Get-TestPage $state 'lab') 'cnt-HTML5GW-inc' | Should -BeTrue
    }
}

Describe 'PTA' {
    BeforeAll {
        $ptaMedia = Join-Path $TestDrive 'pta-media'
        New-TestZip (Join-Path $ptaMedia 'PTA-Installer-Rls-v15.2.2.zip') @('pta_installer.sh', 'pta-15.2.2.tgz')
        New-TestZip (Join-Path $ptaMedia 'PTA-Upgrade-Rls-v15.2.2.zip') @('x')
        New-TestZip (Join-Path $ptaMedia 'PrivilegedSessionManagerSSHProxy-RHELinux9-Intel64-Rls-v15.2.1.zip') @('CARKpsmp-15.2.1.24.x86_64.rpm', 'RPM-GPG-KEY-CyberArk')
        $script:ptaInventory = @($script:inventory | Where-Object { $_.Component -ne 'PSMP' }) + @(Get-PASMediaInventory -Path $ptaMedia)
        $script:ptaSelection = Get-PASMediaSelection -Inventory $script:ptaInventory
        $script:ptaLab = @(@{ Type = 'PVWA'; Name = 'PAS-PVWA'; Address = '192.0.2.33' }, @{ Type = 'PTA'; Name = 'pta01'; Address = '192.0.2.37'; VaultTimezone = 'Europe/Berlin' })
        $script:SavedPtaDataRoot = $env:PAS_EASY_DATA_ROOT
    }
    It 'finds the installer package, not the upgrade package' {
        $items = @($script:ptaInventory | Where-Object Component -eq 'PTA')
        $items.Count | Should -Be 1
        $items[0].Name | Should -Be 'PTA-Installer-Rls-v15.2.2.zip'
        $items[0].Version | Should -Be '15.2.2'
    }
    It 'takes the signing key from the PSMP package, comes last and gets the Vault time zone' {
        $cfg = New-PASLabConfiguration -Environment PtaLab -VaultMode Primary -PrimaryAddress 192.0.2.31 -ControllerAddress 198.51.100.250 `
            -Media $script:ptaSelection -SecurityProfile Lab -AcceptEula -Instances $script:ptaLab
        $check = Test-PASLabConfiguration -Configuration $cfg
        $check.Issues | Should -BeNullOrEmpty
        ($check.Warnings -join ' ') | Should -Not -Match 'assumes that the Vault server runs in UTC'
        [IO.Path]::GetFileName([string]$cfg.options.cyberArkRpmKey) | Should -Be 'RPM-GPG-KEY-CyberArk'
        Test-Path -LiteralPath $cfg.options.cyberArkRpmKey | Should -BeTrue
        $pta = @($cfg.components | Where-Object type -eq 'PTA')[0]
        $pta.options.vaultTimezone | Should -Be 'Europe/Berlin'
        $pta.options.pvwaTrustFrom | Should -Be 'pas-pvwa'
        $plan = Get-PASLabPlan -Configuration $cfg
        $plan.Items[-1].Type | Should -Be 'PTA'
        $inventory = & (Get-Module -Name PASeasyInstall) { param($c) New-PASRuntimeInventory -Config $c -CredentialMap @{} -SkipMediaHash -ComponentId 'pta01' } $cfg
        $settings = $inventory.Values.Components['pta01']
        $settings.PvwaHost | Should -Be 'PAS-PVWA'
        $settings.PvwaAddress | Should -Be '192.0.2.33'
        $settings.VaultTimezone | Should -Be 'Europe/Berlin'
        $settings.RpmKeyTarget | Should -Be '/opt/paeasyinstall/media/pta01/RPM-GPG-KEY-CyberArk'
    }
    It 'names what is missing: the license agreement, a PVWA, the signing key; and warns about UTC' {
        $bare = New-PASLabConfiguration -Environment PtaLab -VaultMode Existing -ExistingVaultAddress 192.0.2.5 -Media ($script:ptaSelection.Clone()) -SecurityProfile Lab `
            -Instances @(@{ Type = 'PTA'; Name = 'pta01'; Address = '192.0.2.37' })
        $text = (Test-PASLabConfiguration -Configuration $bare).Issues -join ' '
        $text | Should -Match 'license agreement \(EULA\) for PTA'
        $text | Should -Match 'needs a PVWA in the same lab'
        $noKey = $script:ptaSelection.Clone()
        $noKey.Remove('PSMP')
        $cfg = New-PASLabConfiguration -Environment PtaLab -VaultMode Primary -PrimaryAddress 192.0.2.31 -ControllerAddress 198.51.100.250 `
            -Media $noKey -SecurityProfile Lab -AcceptEula -Instances @(@{ Type = 'PVWA'; Name = 'PAS-PVWA'; Address = '192.0.2.33' }, @{ Type = 'PTA'; Name = 'pta01'; Address = '192.0.2.37' })
        $check = Test-PASLabConfiguration -Configuration $cfg
        ($check.Issues -join ' ') | Should -Match 'needs a PSMP package in the media folder'
        ($check.Warnings -join ' ') | Should -Match 'assumes that the Vault server runs in UTC'
    }
    It 'is one more component in the window, on its own Linux server' {
        $state = New-PASUIState
        Set-PASUIPreset $state 'standard'
        $state.Counts['PTA'] = 1
        $state.VaultTimezone = 'Europe/Berlin'
        $slot = @(Get-PASUIServerSlots $state | Where-Object { $_.Types -contains 'PTA' })
        $slot.Count | Should -Be 1
        $slot[0].Os | Should -Be 'Linux'
        (Get-PASUIInstances $state | Where-Object Type -eq 'PTA').VaultTimezone | Should -Be 'Europe/Berlin'
        $state.Preset = 'custom'
        Test-PageControl (Get-TestPage $state 'lab') 'cnt-PTA-inc' | Should -BeTrue
        $state.Advanced = $true
        (Find-PASUIControl (Get-TestPage $state 'servers').Panel 'f-vault-timezone').Text | Should -Be 'Europe/Berlin'
        (Get-PASUIInputIssues $state 'servers') -join ' ' | Should -Match 'license agreement of the Linux installers'
    }
}
