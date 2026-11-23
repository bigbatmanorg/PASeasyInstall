BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $helperPath = Join-Path $repo 'PASeasyInstall/Recipes/Vault/Tasks/Common/VaultPadr.ps1'
    $helper = [IO.File]::ReadAllText($helperPath)
    . $helperPath
    function Get-Service { param($Name, $DisplayName) }
    function Set-Service { param($Name, $StartupType) }
    function Stop-Service { param($Name, [switch]$Force) }
    function Start-Service { param($Name) }
    function icacls.exe { param([Parameter(ValueFromRemainingArguments)]$Arguments) $global:LASTEXITCODE = 0 }
    function Restart-Service { param($Name, [switch]$Force) }
    $taskRoot = Join-Path $repo 'PASeasyInstall/Recipes/Vault/Tasks'
    $wait = [IO.File]::ReadAllText((Join-Path $taskRoot 'VaultDR/Wait-Replication.ps1')).Replace('# PAEASY_INCLUDE_VAULT_PADR', $helper)
    $verify = [IO.File]::ReadAllText((Join-Path $taskRoot 'Verify/Verify-DR.ps1')).Replace('# PAEASY_INCLUDE_VAULT_PADR', $helper)
    $installed = [IO.File]::ReadAllText((Join-Path $taskRoot 'Verify/Verify-PADRInstalled.ps1')).Replace('# PAEASY_INCLUDE_VAULT_PADR', $helper)
    $install = [IO.File]::ReadAllText((Join-Path $taskRoot 'VaultDR/Install-PADR.ps1')).Replace('# PAEASY_INCLUDE_VAULT_PADR', $helper)
    $configure = [IO.File]::ReadAllText((Join-Path $repo 'PASeasyInstall/Recipes/Vault/Tasks/VaultDR/Configure-PADR.ps1')).Replace('# PAEASY_INCLUDE_VAULT_PADR', $helper)
}
Describe 'PADR manual standby guards (isolated service and real temporary INI fixtures)' {
    BeforeEach {
        $settings = @{InstallRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N')); PrimaryIP = '192.0.2.120' }
        $conf = Join-Path $settings.InstallRoot 'PADR/Conf'
        [void](New-Item $conf -ItemType Directory -Force)
        $file = Join-Path $conf 'PADR.ini'
        $vault = Join-Path $conf 'Vault.ini'
        [IO.File]::WriteAllText($file, "EnableFailover=Yes`r`nFailoverMode=NO`r`nActivateManualFailover=No`r`nEnableCheck=Yes`r`nEnableReplicate=Yes`r`nNextBinaryLogNumberToStartAt=71`r`nLastDataReplicationTimestamp=NativeOnly")
        [IO.File]::WriteAllText($vault, "ADDRESS=192.0.2.120`r`nPORT=1858")
        $script:PadrService = [pscustomobject]@{Name = 'PADR'; Status = 'Stopped'; StartType = 'Manual' }
        $script:ServerStatus = 'Stopped'
        Mock Get-Service {
            param($DisplayName, $Name)
            if ($DisplayName -eq 'CyberArk Vault Disaster Recovery' -or $Name -eq 'PADR') { return $script:PadrService }
            if ($DisplayName -eq 'PrivateArk Database') { return [pscustomobject]@{Status = 'Running'; StartType = 'Automatic' } }
            [pscustomobject]@{Status = $script:ServerStatus; StartType = 'Manual' }
        }
        Mock Set-Service { param($StartupType) $script:PadrService.StartType = $StartupType }
        Mock Stop-Service { $script:PadrService.Status = 'Stopped' }
        Mock Start-Service {
            # Prove the policy is persisted before any service start is attempted.
            Assert-PASeasyPadrManualStandby $settings
            $script:PadrService.Status = 'Running'
        }
        Mock Restart-Service { throw 'Configure must quiesce and validate rather than blindly restart' }
    }
    It 'sets automatic failover policy No before the first allowed service start without rewriting native state/internal markers' {
        $result = & ([scriptblock]::Create($configure)) -Settings $settings
        $result.Changed | Should -BeTrue
        Read-PASeasyPadrIniValue $file EnableFailover | Should -BeExactly No
        Read-PASeasyPadrIniValue $file FailoverMode | Should -BeExactly NO
        Read-PASeasyPadrIniValue $file NextBinaryLogNumberToStartAt | Should -BeExactly 71
        Read-PASeasyPadrIniValue $file LastDataReplicationTimestamp | Should -BeExactly NativeOnly
        Should -Invoke Start-Service -Times 1
    }
    It 'refuses already activated state before any write or service mutation' {
        [IO.File]::AppendAllText($file, "`r`n# retained evidence")
        $text = [IO.File]::ReadAllText($file).Replace('FailoverMode=NO', 'FailoverMode=Yes')
        [IO.File]::WriteAllText($file, $text)
        { & ([scriptblock]::Create($configure)) -Settings $settings } | Should -Throw '*vendor recovery*'
        [IO.File]::ReadAllText($file) | Should -BeExactly $text
        Should -Invoke Stop-Service -Times 0
        Should -Invoke Set-Service -Times 0
        Should -Invoke Start-Service -Times 0
    }
    It 'refuses manual activation and contradictory duplicate keys' {
        foreach ($text in @("FailoverMode=No`nActivateManualFailover=Yes", "FailoverMode=No`nFailoverMode=Yes", "FailoverMode=No`nActivateManualFailover=No`nActivateManualFailover=Yes")) {
            [IO.File]::WriteAllText($file, $text)
            { Assert-PASeasyPadrNotActivated $settings } | Should -Throw
        }
    }
    It 'requires a known state and refuses NUL corruption' {
        foreach ($text in @('EnableFailover=Yes', 'FailoverMode=unknown', ("FailoverMode=No" + [char]0))) {
            [IO.File]::WriteAllText($file, $text)
            { Assert-PASeasyPadrNotActivated $settings } | Should -Throw
        }
    }
    It 'independently rejects unsafe automatic policy despite FailoverMode No' {
        { Assert-PASeasyPadrManualStandby $settings } | Should -Throw '*EnableFailover*'
    }
    It 'refuses a running standby Vault before changing policy' {
        $script:ServerStatus = 'Running'
        $before = [IO.File]::ReadAllText($file)
        { & ([scriptblock]::Create($configure)) -Settings $settings } | Should -Throw '*stopped/manual*'
        [IO.File]::ReadAllText($file) | Should -BeExactly $before
        Should -Invoke Start-Service -Times 0
    }
    It 'rechecks activated state after stopping an existing PADR worker and preserves activation evidence' {
        $script:PadrService.Status = 'Running'
        Mock Stop-Service {
            $script:PadrService.Status = 'Stopped'
            [IO.File]::WriteAllText($file, [IO.File]::ReadAllText($file).Replace('FailoverMode=NO', 'FailoverMode=Yes'))
        }
        { & ([scriptblock]::Create($configure)) -Settings $settings } | Should -Throw '*failover state*'
        Read-PASeasyPadrIniValue $file EnableFailover | Should -BeExactly Yes
        Should -Invoke Start-Service -Times 0
    }
    It 'makes historical automatic PADR manual before stopping or changing policy' {
        $script:PadrService.Status = 'Running'
        $script:PadrService.StartType = 'Automatic'
        Mock Stop-Service {
            if ($script:PadrService.StartType -ne 'Manual') { throw 'Unsafe automatic restart boundary' }
            $script:PadrService.Status = 'Stopped'
        }
        & ([scriptblock]::Create($configure)) -Settings $settings | Out-Null
        Should -Invoke Stop-Service -Times 1
        $script:PadrService.StartType | Should -BeExactly Automatic
    }
    It 'leaves PADR manual and stopped when a policy write fails' {
        $script:PadrService.Status = 'Running'
        $script:PadrService.StartType = 'Automatic'
        # A textual helper definition in the task replaces Pester mocks: inject only the actual
        # failing writer while retaining the complete production Configure body and other guards.
        $body = $configure -replace '(?s)function Set-PASeasyPadrIniValue \{.*?\r?\n\}', 'function Set-PASeasyPadrIniValue {throw "Synthetic write failure"}'
        { & ([scriptblock]::Create($body)) -Settings $settings } | Should -Throw '*write failure*'
        $script:PadrService.Status | Should -BeExactly Stopped
        $script:PadrService.StartType | Should -BeExactly Manual
        Should -Invoke Start-Service -Times 0
    }
    It 'Wait refuses unsafe settings before any restart or start even on a requested forced cycle' {
        { & ([scriptblock]::Create($wait)) -Settings $settings -Restart -Minutes 0 } | Should -Throw '*EnableFailover*'
        Should -Invoke Restart-Service -Times 0
        Should -Invoke Start-Service -Times 0
    }
    It 'Wait accepts a test Safe that the DR Vault replicated before this step started (fresh cycle after it)' {
        [void](Set-PASeasyPadrIniValue $file EnableFailover No)
        $script:PadrService.Status = 'Running'
        $logdir = Join-Path $settings.InstallRoot 'PADR/Logs'
        [void](New-Item $logdir -ItemType Directory -Force)
        $ci = [Globalization.CultureInfo]::InvariantCulture
        $old = (Get-Date).AddMinutes(-3).ToString('dd/MM/yyyy HH:mm:ss', $ci)
        $now = (Get-Date).AddSeconds(5).ToString('dd/MM/yyyy HH:mm:ss', $ci)
        $runId = '0123456789abcdef0123456789abcdef'
        $safe = 'PAExecRepl' + $runId.Substring(0, 12)
        $lines = @(
            ('[{0}] PAREP0213I Safe [{1}(12)] Replicated [3] files' -f $old, $safe),
            ('[{0}] PADR0010I Replication cycle completed' -f $old),
            ('[{0}] PADR0010I Replication cycle completed' -f $now),
            ('[{0}] PADR0099I Metadata replication' -f $now))
        [IO.File]::WriteAllText((Join-Path $logdir 'padr.log'), ($lines -join "`n"))
        $result = & ([scriptblock]::Create($wait)) -Settings $settings -Minutes 1 -RunId $runId -TestSafe
        $result.Message | Should -Match ([regex]::Escape($safe) + ' replicated')
        # Without any replication line for this run's Safe the step does not complete.
        [IO.File]::WriteAllText((Join-Path $logdir 'padr.log'), (($lines | Select-Object -Skip 1) -join "`n"))
        Mock Start-Sleep {}
        { & ([scriptblock]::Create($wait)) -Settings $settings -Minutes 0 -RunId $runId -TestSafe } | Should -Throw '*No fresh PADR cycle*'
    }
    It 'independent installed verification refuses the native automatic default' {
        $settings.PackagesRoot = Join-Path $TestDrive packages
        $result = & ([scriptblock]::Create($installed)) -Settings $settings
        $result.Passed | Should -BeFalse
        $result.Message | Should -Match 'EnableFailover'
    }
    It 'full independent verification accepts fresh replication only with safe flags and all standby services' {
        [void](Set-PASeasyPadrIniValue $file EnableFailover No)
        $script:PadrService.Status = 'Running'
        $script:PadrService.StartType = 'Automatic'
        $logdir = Join-Path $settings.InstallRoot 'PADR/Logs'
        [void](New-Item $logdir -ItemType Directory)
        $stamp = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
        [IO.File]::WriteAllText((Join-Path $logdir 'padr.log'), ("[{0}] PADR0200I session`n[{0}] PADR0010I completed`n[{0}] PADR0099I metadata" -f $stamp))
        (& ([scriptblock]::Create($verify)) -Settings $settings).Passed | Should -BeTrue
        [IO.File]::AppendAllText($file, "`nEnableFailover=Yes")
        $bad = & ([scriptblock]::Create($verify)) -Settings $settings
        $bad.Passed | Should -BeFalse
        $bad.Message | Should -Match 'exactly one EnableFailover'
    }
    It 'does not accept duplicate address, disabled replication, or duplicate policy' {
        [void](Set-PASeasyPadrIniValue $file EnableFailover No)
        foreach ($bad in @("ADDRESS=192.0.2.120`nADDRESS=192.0.2.121", 'ADDRESS=192.0.2.121')) {
            [IO.File]::WriteAllText($vault, $bad)
            { Assert-PASeasyPadrManualStandby $settings } | Should -Throw
        }
        [IO.File]::WriteAllText($vault, 'ADDRESS=192.0.2.120')
        [void](Set-PASeasyPadrIniValue $file EnableReplicate No)
        { Assert-PASeasyPadrManualStandby $settings } | Should -Throw '*EnableReplicate*'
    }
}

Describe 'PADR no-reboot install return boundary (mock vendor process only)' {
    BeforeEach {
        $settings = @{
            InstallRoot = Join-Path $TestDrive install
            PrimaryIP = '192.0.2.120'
            PackagesRoot = Join-Path $TestDrive packages
            AutomationRoot = Join-Path $TestDrive automation
        }
        $conf = Join-Path $settings.InstallRoot 'PADR/Conf'
        [void](New-Item $conf -ItemType Directory -Force)
        $file = Join-Path $conf 'PADR.ini'
        $vault = Join-Path $conf 'Vault.ini'
        [IO.File]::WriteAllText($file, "EnableFailover=Yes`nFailoverMode=No`nActivateManualFailover=No`nEnableCheck=Yes`nEnableReplicate=Yes")
        [IO.File]::WriteAllText($vault, 'ADDRESS=192.0.2.120')
        $folder = Join-Path $settings.PackagesRoot 'Disaster Recovery'
        [void](New-Item $folder -ItemType Directory -Force)
        [IO.File]::WriteAllText((Join-Path $folder 'setup.exe'), 'TEST FIXTURE ONLY - NEVER EXECUTED')
        $templates = Join-Path $settings.AutomationRoot Templates
        [void](New-Item $templates -ItemType Directory -Force)
        $template = Join-Path $templates 'vaultdr-iss.j2'
        [IO.File]::WriteAllText($template, "BootOption=0`nMasterVaultAddress=127.0.0.1`nDRUserPass={{ ansible_stripped_password }}")
        $script:NativeInstalled = $false
        $script:NativeStatus = 'Stopped'
        $script:NativeFailover = 'No'
        $script:NativeStartup = 'Automatic'
        Mock Get-Service {
            param($DisplayName)
            if ($DisplayName -eq 'CyberArk Vault Disaster Recovery') {
                if ($script:NativeInstalled) {
                    return [pscustomobject]@{
                        Name = 'PADR'
                        Status = $script:NativeStatus
                        StartType = $script:NativeStartup
                    }
                }
                return $null
            }
            if ($DisplayName -eq 'PrivateArk Database') { return [pscustomobject]@{Status = 'Running'; StartType = 'Automatic' } }
            [pscustomobject]@{Status = 'Stopped'; StartType = 'Manual' }
        }
        Mock Start-Process {
            $script:NativeInstalled = $true
            [IO.File]::WriteAllText((Join-Path $folder 'setup.log'), 'ResultCode=0')
            [IO.File]::WriteAllText($file, [IO.File]::ReadAllText($file).Replace('FailoverMode=No', ('FailoverMode=' + $script:NativeFailover)))
            [pscustomobject]@{ExitCode = 0 }
        }
        Mock Get-Process { $null }
        Mock Set-Service { param($StartupType)$script:NativeStartup = $StartupType }
        Mock Stop-Service { $script:NativeStatus = 'Stopped' }
        Mock Start-Service { throw 'No PADR start is allowed in Install' }
    }
    It 'requires exactly one no-reboot response before any installer execution' {
        foreach ($bad in @('BootOption=1', "BootOption=0`nBootOption=1", 'NoBootOption=0')) {
            [IO.File]::WriteAllText($template, ($bad + "`nMasterVaultAddress=127.0.0.1"))
            { & ([scriptblock]::Create($install)) -Settings $settings -DRPassword 'SyntheticOnly' } | Should -Throw '*BootOption*'
        }
        Should -Invoke Start-Process -Times 0
    }
    It 'publishes normal stopped install only after manual startup and automatic-failover No are persisted' {
        & ([scriptblock]::Create($install)) -Settings $settings -DRPassword 'SyntheticOnly' | Out-Null
        $script:NativeStartup | Should -BeExactly Manual
        Read-PASeasyPadrIniValue $file EnableFailover | Should -BeExactly No
        Test-Path (Join-Path $folder 'setup.iss') | Should -BeFalse
        Should -Invoke Start-Service -Times 0
    }
    It 'contains unexpected Running after setup and fails rather than publishing success' {
        $script:NativeStatus = 'Running'
        { & ([scriptblock]::Create($install)) -Settings $settings -DRPassword 'SyntheticOnly' } | Should -Throw '*unexpectedly started*'
        $script:NativeStartup | Should -BeExactly Manual
        $script:NativeStatus | Should -BeExactly Stopped
        Test-Path (Join-Path $folder 'setup.iss') | Should -BeFalse
        Read-PASeasyPadrIniValue $file EnableFailover | Should -BeExactly Yes
    }
    It 'preserves activated native state without clearing failover after setup' {
        $script:NativeFailover = 'Yes'
        { & ([scriptblock]::Create($install)) -Settings $settings -DRPassword 'SyntheticOnly' } | Should -Throw '*vendor recovery*'
        Read-PASeasyPadrIniValue $file FailoverMode | Should -BeExactly Yes
        Should -Invoke Set-Service -Times 0
        Should -Invoke Start-Service -Times 0
    }
}
Describe 'PADR static recipe helper inclusion (root-owned payload allowlist prerequisite)' {
    BeforeAll {
        $script:PASRoot = Join-Path $repo PASeasyInstall
        function Test-PASWindows { return $env:OS -eq 'Windows_NT' }
        # Get-PASRecipePayload resolves its helpers with Get-PASModuleRoot / Get-PASRecipePath.
        . (Join-Path $script:PASRoot 'Private/Common/ModulePaths.ps1')
        . (Join-Path $script:PASRoot 'Private/Engine/RecipePayload.ps1')
    }
    It 'ships the immutable manual-standby guard to every PADR start and independent verification task' {
        foreach ($relative in @('VaultDR/Configure-PADR.ps1', 'VaultDR/Install-PADR.ps1', 'VaultDR/Wait-Replication.ps1', 'Verify/Verify-DR.ps1', 'Verify/Verify-PADRInstalled.ps1')) {
            $payload = Get-PASRecipePayload (Join-Path $script:PASRoot ('Recipes/Vault/Tasks/' + $relative))
            $payload.Text | Should -Not -Match 'PAEASY_INCLUDE_'
            $payload.Text | Should -Match 'function Assert-PASeasyPadrManualStandby'
            @($payload.Files | Where-Object { $_ -like '*VaultPadr.ps1' }).Count | Should -Be 1
        }
    }
}
