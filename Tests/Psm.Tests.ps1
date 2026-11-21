BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall/Recipes/WindowsComponent/Psm.ps1')
    function Invoke-VendorScript {
        param(
            $ScriptPath,
            $Parameters,
            [switch]$AllowEmptyNativeStderr,
            [switch]$AllowPinnedRegImportSuccess
        )
    }
}
Describe 'PSM controller-owned reboot continuation contract' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $payload = Join-Path $root 'payload/InstallationAutomation'
        New-Item (Join-Path $payload 'Prerequisites') -ItemType Directory -Force | Out-Null
        New-Item (Join-Path $payload 'Installation') -ItemType Directory -Force | Out-Null
        Set-Content (Join-Path $payload 'Execute-Stage.ps1') '# test fixture'
        Set-Content (Join-Path $payload 'Prerequisites/PrerequisitesConfig.xml') '<Stage Name="Prerequisites"/>'
        Set-Content (Join-Path $payload 'Installation/InstallationConfig.xml') '<Stage Name="Installation"/>'
        $settings = @{StageRoot = $root; Options = @{}; ApplyHardening = $true }
        Mock Assert-PASeasyPsmTlsBackupTrusted {}
        Mock Protect-PASeasyPsmTempDirectory {}
        Mock Assert-PASeasyPsmTempDirectory {}
        Mock Set-PASeasyPsmRdpTls {}
        Mock Get-CimInstance { [pscustomobject]@{LastBootUpTime = [datetime]'2026-11-16T12:00:00Z' } }
        Mock Get-ItemProperty { $null }
        Mock Invoke-VendorScript { [pscustomobject]@{isSucceeded = 0; restartRequired = $true } }
    }
    It 'rejects an untrusted global backup before prerequisites or any vendor execution' {
        Mock Assert-PASeasyPsmTlsBackupTrusted { throw 'PSM TLS backup untrusted fixture' }
        { Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings } | Should -Throw '*untrusted fixture*'
        Should -Invoke Invoke-VendorScript -Exactly 0
        Should -Invoke Protect-PASeasyPsmTempDirectory -Exactly 0
    }
    It 'requests delayed restart and completes the stage before yielding to the controller' {
        Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings | Out-Null
        Should -Invoke Invoke-VendorScript -Exactly 1 -ParameterFilter {
            $Parameters.silentMode -eq 'Silent' -and $Parameters.delayedrestart -eq $true -and
            $Parameters.restartAfterStageCompleted -eq $true -and $Parameters.displayJson -eq $true -and -not $AllowEmptyNativeStderr -and -not $AllowPinnedRegImportSuccess
        }
        $record = Get-Content (Join-Path $root 'stage/Prerequisites.json') -Raw | ConvertFrom-Json
        $record.restartRequired | Should -BeTrue
        $record.schemaVersion | Should -Be 2
    }
    It 'refuses the next stage until a requested reboot changes boot identity' {
        Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings | Out-Null
        { Invoke-PASeasyPsmStage -Stage Install -Settings $settings } | Should -Throw '*controller-confirmed reboot*'
        Should -Invoke Invoke-VendorScript -Exactly 1
    }
    It 'never launches a completed stage again' {
        Mock Invoke-VendorScript { [pscustomobject]@{isSucceeded = 0; restartRequired = $false } }
        Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings | Out-Null
        $result = Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings
        $result.Changed | Should -BeFalse
        Should -Invoke Invoke-VendorScript -Exactly 1
    }
    It 'rejects pre-existing plaintext Winlogon continuation without copying the secret' {
        Mock Get-ItemProperty { [pscustomobject]@{DefaultPassword = 'synthetic-marker' } } -ParameterFilter { $Path -like '*Winlogon' }
        { Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings } | Should -Throw '*plaintext Winlogon*'
        Should -Invoke Invoke-VendorScript -Exactly 0
        Test-Path (Join-Path $root 'stage/Prerequisites.json') | Should -BeFalse
    }
    It 'does not claim success without a vendor reboot result' {
        Mock Invoke-VendorScript { [pscustomobject]@{isSucceeded = 0 } }
        { Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings } | Should -Throw '*restartRequired*'
        Test-Path (Join-Path $root 'stage/Prerequisites.json') | Should -BeFalse
    }
    It 'continues only after a proven reboot and clears the pending restart after vendor completion' {
        Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings | Out-Null
        Mock Get-CimInstance { [pscustomobject]@{LastBootUpTime = [datetime]'2026-11-16T13:00:00Z' } }
        Mock Invoke-VendorScript { [pscustomobject]@{isSucceeded = 0; restartRequired = $false } }
        $result = Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings
        $result.Data.RebootRequired | Should -BeFalse
        (Get-Content (Join-Path $root 'stage/Prerequisites.json') -Raw | ConvertFrom-Json).restartRequired | Should -BeFalse
        Should -Invoke Invoke-VendorScript -Exactly 2
    }
    It 'keeps the next phase blocked until same-stage continuation completes after reboot' {
        Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings | Out-Null
        Mock Get-CimInstance { [pscustomobject]@{LastBootUpTime = [datetime]'2026-11-16T13:00:00Z' } }
        { Invoke-PASeasyPsmStage -Stage Install -Settings $settings } | Should -Throw '*stage continuation*'
        Should -Invoke Invoke-VendorScript -Exactly 1
    }

    It 'rejects string reboot claims instead of converting false text into true' {
        Mock Invoke-VendorScript { [pscustomobject]@{isSucceeded = 0; restartRequired = 'false' } }
        { Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings } | Should -Throw '*JSON boolean*'
        Test-Path (Join-Path $root 'stage/Prerequisites.json') | Should -BeFalse
    }

    It 'opts into bounded native status compatibility during actual hardening' {
        New-Item (Join-Path $payload 'Hardening') -ItemType Directory | Out-Null
        Set-Content (Join-Path $payload 'Hardening/HardeningConfig.xml') '<Stage Name="Hardening"><Step Name="OutOfDomainHardening" Enable="No"/></Stage>'
        New-Item (Join-Path $root 'stage') -ItemType Directory | Out-Null
        @{
            schemaVersion = 2
            stage = 'Register'
            restartRequired = $false
        } | ConvertTo-Json | Set-Content (Join-Path $root 'stage/Register.json')
        Mock Invoke-VendorScript { [pscustomobject]@{isSucceeded = 0; restartRequired = $false } }
        Mock Get-ItemProperty {
            if ($LiteralPath -like '*TLS 1.2*') {
                [pscustomobject]@{
                    Enabled = [int]1
                    DisabledByDefault = [int]0
                }
            } else {
                [pscustomobject]@{
                    Enabled = [int]0
                    DisabledByDefault = [int]1
                }
            }
        } -ParameterFilter { $LiteralPath -like '*SCHANNEL*' }
        Invoke-PASeasyPsmStage -Stage Harden -Settings $settings | Out-Null
        Should -Invoke Invoke-VendorScript -Exactly 1 -ParameterFilter { $AllowEmptyNativeStderr -and $AllowPinnedRegImportSuccess }
        $xml = [xml](Get-Content (Join-Path $payload 'Hardening/HardeningConfig.xml') -Raw)
        $xml.Stage.Step.Enable | Should -Be 'Yes'
    }


    It 'also scopes native status compatibility and TLS checks to PostInstallation' {
        New-Item (Join-Path $payload 'PostInstallation') -ItemType Directory | Out-Null
        Set-Content (Join-Path $payload 'PostInstallation/PostInstallationConfig.xml') '<Stage Name="PostInstallation"/>'
        New-Item (Join-Path $root 'stage') -ItemType Directory | Out-Null
        @{
            schemaVersion = 2
            stage = 'Harden'
            restartRequired = $false
        } | ConvertTo-Json | Set-Content (Join-Path $root 'stage/Harden.json')
        Mock Get-ItemProperty {
            if ($LiteralPath -like '*TLS 1.2*') {
                [pscustomobject]@{
                    Enabled = [int]1
                    DisabledByDefault = [int]0
                }
            } else {
                [pscustomobject]@{
                    Enabled = [int]0
                    DisabledByDefault = [int]1
                }
            }
        } -ParameterFilter { $LiteralPath -like '*SCHANNEL*' }
        Mock Invoke-VendorScript { [pscustomobject]@{isSucceeded = 0; restartRequired = $false } }
        Invoke-PASeasyPsmStage -Stage PostInstall -Settings $settings | Out-Null
        Should -Invoke Invoke-VendorScript -Exactly 1 -ParameterFilter { $AllowEmptyNativeStderr -and $AllowPinnedRegImportSuccess -and $Parameters.configFilePath -like '*PostInstallation*PostInstallationConfig.xml' }
    }
    It 'detects plaintext Winlogon armed by a failed vendor without exposing its value' {
        $global:PAeasyPsmTestVendorRan = $false
        Mock Get-ItemProperty { if ($global:PAeasyPsmTestVendorRan) { [pscustomobject]@{DefaultPassword = 'SYNTHETIC_FAILURE_SECRET' } } } -ParameterFilter { $Path -like '*Winlogon' }
        Mock Invoke-VendorScript {
            $global:PAeasyPsmTestVendorRan = $true
            throw 'Synthetic vendor failure'
        }
        try {
            { Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings } | Should -Throw '*plaintext Winlogon*'
            Test-Path (Join-Path $root 'stage/Prerequisites.json') | Should -BeFalse
        } finally { Remove-Variable PAeasyPsmTestVendorRan -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'refuses completed checkpoints if vendor interactive recovery is now armed' {
        Mock Invoke-VendorScript { [pscustomobject]@{isSucceeded = 0; restartRequired = $false } }
        Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings | Out-Null
        Mock Get-ItemProperty { [pscustomobject]@{Recovery = 'powershell InstallationAutomationRecovery.ps1' } } -ParameterFilter { $Path -like '*RunOnce' }
        { Invoke-PASeasyPsmStage -Stage Prerequisites -Settings $settings } | Should -Throw '*interactive recovery detected*'
        Should -Invoke Invoke-VendorScript -Exactly 1
        (Invoke-PASeasyPsmVerify -Stage Prerequisites -Settings $settings).Passed | Should -BeFalse
    }

}

Describe 'PSM TLS restoration postconditions' {
    BeforeEach {
        Mock Get-ItemProperty {
            if ($LiteralPath -like '*TLS 1.2*') {
                [pscustomobject]@{
                    Enabled = [int]1
                    DisabledByDefault = [int]0
                }
            } else {
                [pscustomobject]@{
                    Enabled = [int]0
                    DisabledByDefault = [int]1
                }
            }
        }
    }
    It 'independently confirms all six client and server protocol settings' {
        { Assert-PASeasyPsmTlsRestored } | Should -Not -Throw
        Should -Invoke Get-ItemProperty -Exactly 6
    }
    It 'refuses legacy TLS left enabled by an incomplete vendor restore' {
        Mock Get-ItemProperty { [pscustomobject]@{
                Enabled = [int]1
                DisabledByDefault = [int]0
            } } -ParameterFilter { $LiteralPath -like '*TLS 1.0*' }
        { Assert-PASeasyPsmTlsRestored } | Should -Throw '*TLS registry postcondition*'
    }
    It 'refuses string registry data that Schannel would not treat as DWORD policy' {
        Mock Get-ItemProperty { [pscustomobject]@{
                Enabled = '0'
                DisabledByDefault = '1'
            } } -ParameterFilter { $LiteralPath -like '*TLS 1.1*' }
        { Assert-PASeasyPsmTlsRestored } | Should -Throw '*TLS registry postcondition*'
    }
}

Describe 'PSM native TLS backup ownership' {
    BeforeEach {
        $backup = Join-Path $TestDrive 'tls.reg'
        Set-Content $backup 'nonsecret fixture'
        Mock Assert-PASeasyPsmTlsBackupData {}
    }
    It 'rejects a dangling reparse entry even when Test-Path would report false' {
        Mock Test-Path { $false }
        Mock Get-Acl { throw 'ACL must not be read for reparse entry' }
        Mock Get-Item { [pscustomobject]@{Attributes = [IO.FileAttributes]::ReparsePoint; PSIsContainer = $false } }
        { Assert-PASeasyPsmTlsBackupTrusted -BackupPath $backup } | Should -Throw '*reparse ancestor*'
        Should -Invoke Get-Acl -Exactly 0
    }
    It 'rejects generic-write permissions on a preexisting backup' {
        Mock Get-Acl {
            $a = [Security.AccessControl.FileSecurity]::new()
            $a.SetSecurityDescriptorSddlForm('O:BAG:SYD:P(A;;GW;;;AU)')
            $a
        }
        { Assert-PASeasyPsmTlsBackupTrusted -BackupPath $backup } | Should -Throw '*untrusted writer*'
    }
    It 'rejects an untrusted owner before the vendor can import a precreated backup' {
        Mock Get-Acl {
            $a = [Security.AccessControl.FileSecurity]::new()
            $a.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'))
            $a
        }
        { Assert-PASeasyPsmTlsBackupTrusted -BackupPath $backup } | Should -Throw '*untrusted owner*'
    }
    It 'rejects a trusted-owned backup that permits everyone to write' {
        Mock Get-Acl {
            $a = [Security.AccessControl.FileSecurity]::new()
            $a.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
            $a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-1-0'), [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
            $a
        }
        { Assert-PASeasyPsmTlsBackupTrusted -BackupPath $backup } | Should -Throw '*untrusted writer*'
    }
}

Describe 'PSM ticket RDP transport prerequisite' {
    It 'accepts native ticket-compatible NLA disabled only with mandatory TLS' {
        Mock Get-CimInstance { [pscustomobject]@{UserAuthenticationRequired = 0; SecurityLayer = 2; MinEncryptionLevel = 3 } }
        { Assert-PASeasyPsmRdpTransport } | Should -Not -Throw
    }
    It 'rejects NLA that prevents the native generated ticket from connecting' {
        Mock Get-CimInstance { [pscustomobject]@{UserAuthenticationRequired = 1; SecurityLayer = 2; MinEncryptionLevel = 3 } }
        { Assert-PASeasyPsmRdpTransport } | Should -Throw '*RDP transport*'
    }
    It 'rejects a negotiate-layer downgrade even when NLA is disabled' {
        Mock Get-CimInstance { [pscustomobject]@{UserAuthenticationRequired = 0; SecurityLayer = 1; MinEncryptionLevel = 3 } }
        { Assert-PASeasyPsmRdpTransport } | Should -Throw '*RDP transport*'
    }
}

Describe 'PSM post-install TLS listener configuration' {
    BeforeEach {
        $script:listener = New-CimInstance -ClientOnly -Namespace root/cimv2/terminalservices -ClassName Win32_TSGeneralSetting -Property @{
            UserAuthenticationRequired = [uint32]0
            SecurityLayer = [uint32]1
            MinEncryptionLevel = [uint32]3
        }
        Mock Get-CimInstance { $script:listener }
        Mock Invoke-CimMethod {
            $script:listener.SecurityLayer = [uint32]2
            [pscustomobject]@{ReturnValue = [uint32]0 }
        }
    }
    It 'requires TLS with a checked native method and independent readback' {
        { Set-PASeasyPsmRdpTls } | Should -Not -Throw
        Should -Invoke Invoke-CimMethod -Exactly 1 -ParameterFilter { $MethodName -eq 'SetSecurityLayer' -and $Arguments.SecurityLayer -eq 2 }
        Should -Invoke Get-CimInstance -Exactly 2
    }
    It 'accepts the actual explicit-null TS provider result only with effective state readback' {
        Mock Invoke-CimMethod {
            $script:listener.SecurityLayer = [uint32]2
            [pscustomobject]@{ReturnValue = $null }
        }
        { Set-PASeasyPsmRdpTls } | Should -Not -Throw
        Should -Invoke Get-CimInstance -Exactly 2
    }
    It 'rejects an unknown result shape even if a method changed the listener' {
        Mock Invoke-CimMethod {
            $script:listener.SecurityLayer = [uint32]2
            [pscustomobject]@{Other = 0 }
        }
        { Set-PASeasyPsmRdpTls } | Should -Throw '*unknown method result*'
    }
    It 'does not rewrite a TLS-secured listener' {
        $script:listener.SecurityLayer = [uint32]2
        { Set-PASeasyPsmRdpTls } | Should -Not -Throw
        Should -Invoke Invoke-CimMethod -Exactly 0
    }
    It 'fails a native method error instead of manufacturing transport success' {
        Mock Invoke-CimMethod { [pscustomobject]@{ReturnValue = [uint32]5 } }
        { Set-PASeasyPsmRdpTls } | Should -Throw '*did not return success*'
    }
    It 'fails a method success that did not change the effective listener' {
        Mock Invoke-CimMethod { [pscustomobject]@{ReturnValue = [uint32]0 } }
        { Set-PASeasyPsmRdpTls } | Should -Throw '*RDP transport*'
    }
    It 'does not override an unmet NLA prerequisite or weak encryption' {
        $script:listener.UserAuthenticationRequired = [uint32]1
        { Set-PASeasyPsmRdpTls } | Should -Throw '*NLA prerequisite*'
        $script:listener.UserAuthenticationRequired = [uint32]0
        $script:listener.MinEncryptionLevel = [uint32]1
        { Set-PASeasyPsmRdpTls } | Should -Throw '*encryption*'
        Should -Invoke Invoke-CimMethod -Exactly 0
    }
}

Describe 'PSM existing TLS backup data scope' {
    BeforeEach { $backup = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.reg') }
    It 'accepts a canonical native TLS-client export only' {
        Set-Content $backup ('Windows Registry Editor Version 5.00' + "`r`n`r`n" + '[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Client]' + "`r`n" + '"Enabled"=dword:00000000') -Encoding Unicode
        { Assert-PASeasyPsmTlsBackupData $backup } | Should -Not -Throw
    }
    It 'rejects a trusted-owned file that imports an unrelated privileged registry key' {
        Set-Content $backup ('Windows Registry Editor Version 5.00' + "`r`n" + '[HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run]') -Encoding Unicode
        { Assert-PASeasyPsmTlsBackupData $backup } | Should -Throw '*outside the native TLS client scope*'
    }
    It 'rejects delete-key or malformed export instructions' {
        Set-Content $backup ('Windows Registry Editor Version 5.00' + "`r`n" + '[-HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Client]') -Encoding Unicode
        { Assert-PASeasyPsmTlsBackupData $backup } | Should -Throw '*outside the native TLS client scope*'
    }
}
