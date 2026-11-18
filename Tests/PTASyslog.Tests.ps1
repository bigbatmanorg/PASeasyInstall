BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    $syslog=Join-Path $root 'Modules/PASeasyInstall.Vault/Recipes/Vault/Tasks/Vault/Configure-PTASyslog.ps1'
    Import-Module (Join-Path $root 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
    # Public test-only certificate; its generated private key was discarded.
    $publicCert=[IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'Fixtures/public-unit-syslog.pem'))
}
Describe 'Vault PTA TLS configuration safety' {
    BeforeEach {
        $script:syslogRoot=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item (Join-Path $script:syslogRoot 'Conf') -ItemType Directory -Force | Out-Null
        New-Item (Join-Path $script:syslogRoot 'Syslog') -ItemType Directory | Out-Null
        & (Get-Module PASeasyInstall.Core) {param($r) Protect-PASDirectory $r} $script:syslogRoot
        $script:dbparm=Join-Path $script:syslogRoot 'Conf/dbparm.ini'
        [IO.File]::WriteAllText($script:dbparm,"[MAIN]`r`nUnrelatedSetting=preserve`r`n[SYSLOG]`r`nUseLegacySyslogFormat=Yes`r`n[OTHER]`r`nOtherSetting=unchanged`r`n",[Text.Encoding]::ASCII)
        [IO.File]::WriteAllText((Join-Path $script:syslogRoot 'Syslog/PTA.xsl'),'fixture-translator')
        [IO.File]::WriteAllText((Join-Path $script:syslogRoot 'Syslog/RFC5424Changes.xsl'),'fixture-import')
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$hash=([BitConverter]::ToString($sha.ComputeHash($publicCert))).Replace('-','')}finally{$sha.Dispose()}
        $script:settings=@{ServerRoot=$script:syslogRoot;Address='192.0.2.10';Port=514;TrustBundleBase64=[Convert]::ToBase64String($publicCert);TrustBundleSHA256=$hash;
            TranslatorSHA256=(Get-FileHash (Join-Path $script:syslogRoot 'Syslog/PTA.xsl')).Hash;
            TranslatorImportSHA256=(Get-FileHash (Join-Path $script:syslogRoot 'Syslog/RFC5424Changes.xsl')).Hash}
        $serviceFixture=[pscustomobject]@{PathName=('"'+$script:syslogRoot+'\dbmain.exe" service db');ProcessId=$PID}
        Mock Get-CimInstance -MockWith ({$serviceFixture}.GetNewClosure())
        Mock Restart-Service {}
        Mock Start-Sleep {}
        Mock Get-Service {param($Name) [pscustomobject]@{Name=$Name;Status='Running';DependentServices=@()}}
    }
    It 'preserves other sections and uses native TLS and reviewed certificate bytes' {
        $result=& $syslog -Settings $script:settings
        $result.Changed | Should -BeTrue
        $content=Get-Content $script:dbparm -Raw
        $content | Should -Match 'UnrelatedSetting=preserve'
        $content | Should -Match 'OtherSetting=unchanged'
        $content | Should -Match 'SyslogServerProtocol=TLS'
        $content | Should -Match 'UseLegacySyslogFormat=No'
        $content | Should -Not -Match 'SyslogServerProtocol=(TCP|UDP)'
        @(Get-ChildItem (Split-Path $script:dbparm) -Filter 'dbparm-before-paeasy-syslog-*.bak').Count | Should -Be 1
        Should -Invoke Restart-Service -Exactly 1
    }
    It 'satisfies the actual task host output and secret-filtering contract' {
        $hostScript=Join-Path $root 'Modules/PASeasyInstall.Core/Private/Engine/Assets/TaskHost.ps1'
        $result=& $hostScript -Code ([IO.File]::ReadAllText($syslog)) -Parameters @{Settings=$script:settings}
        $result.Ok | Should -BeTrue
        $result.Terminal.Data.Hash | Should -Be $script:settings.TrustBundleSHA256
        $result.Terminal.Data.Metadata | Should -BeOfType ([string])
    }
    It 'refuses an unrelated existing SIEM before certificate or config mutation' {
        Add-Content $script:dbparm "[SYSLOG]`r`nSyslogServerIP=192.0.2.99"
        $before=(Get-FileHash $script:dbparm).Hash
        {& $syslog -Settings $script:settings} | Should -Throw '*existing SIEM destination*'
        (Get-FileHash $script:dbparm).Hash | Should -Be $before
        @(Get-ChildItem (Join-Path $script:syslogRoot 'Conf') -Filter 'PASeasy-PTA-syslog-ca-*.pem').Count|Should -Be 0
        Should -Invoke Restart-Service -Exactly 0
    }
    It 'refuses an altered translator before modifying the Vault' {
        [IO.File]::WriteAllText((Join-Path $script:syslogRoot 'Syslog/PTA.xsl'),'unexpected')
        {& $syslog -Settings $script:settings} | Should -Throw '*translator differs*'
        Should -Invoke Restart-Service -Exactly 0
    }
    It 'refuses a domain-joined or wrong-address primary before mutation' {
        $script:settings.VaultAddress='192.0.2.11'
        Mock Get-NetIPAddress {[pscustomobject]@{IPAddress='192.0.2.99'}}
        Mock Get-CimInstance {[pscustomobject]@{PartOfDomain=$true}} -ParameterFilter {$ClassName -eq 'Win32_ComputerSystem'}
        $before=(Get-FileHash $script:dbparm).Hash
        {& $syslog -Settings $script:settings}|Should -Throw '*running workgroup primary*'
        (Get-FileHash $script:dbparm).Hash|Should -BeExactly $before
        Should -Invoke Restart-Service -Exactly 0
    }
    It 'fails closed on a corrupt pending restart journal without restarting services' {
        [IO.File]::WriteAllBytes((Join-Path $script:syslogRoot 'Conf/PASeasy-PTA-syslog-restart.json'),(New-Object byte[] 100))
        {& $syslog -Settings $script:settings}|Should -Throw
        Should -Invoke Restart-Service -Exactly 0
    }
    It 'rechecks primary workgroup identity on an already-configured checkpoint' {
        $null=& $syslog -Settings $script:settings
        $script:settings.VaultAddress='192.0.2.11'
        Mock Get-NetIPAddress {[pscustomobject]@{IPAddress='192.0.2.11'}}
        Mock Get-CimInstance {param($ClassName) if($ClassName -eq 'Win32_ComputerSystem'){return [pscustomobject]@{PartOfDomain=$true}};return [pscustomobject]@{State='Running';ProcessId=$PID}}
        $verify=Join-Path $root 'Modules/PASeasyInstall.Vault/Recipes/Vault/Tasks/Verify/Verify-PTASyslog.ps1'
        {& $verify -Settings $script:settings}|Should -Throw '*running workgroup primary*'
    }
    It 'refuses a malformed certificate even when its input SHA256 was approved' {
        $bytes=[Text.Encoding]::ASCII.GetBytes(('-----BEGIN CERTIFICATE-----'+('A'*256)+'-----END CERTIFICATE-----'))
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$script:settings.TrustBundleSHA256=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
        $script:settings.TrustBundleBase64=[Convert]::ToBase64String($bytes)
        {& $syslog -Settings $script:settings} | Should -Throw '*invalid certificate*'
        Should -Invoke Restart-Service -Exactly 0
        @(Get-ChildItem (Join-Path $script:syslogRoot 'Conf') -Filter 'PASeasy-PTA-syslog-ca-*.pem').Count|Should -Be 0
    }
    It 'rotates reviewed public trust using a new immutable path while preserving the prior bundle' {
        $null=& $syslog -Settings $script:settings
        $old=@(Get-ChildItem (Join-Path $script:syslogRoot 'Conf') -Filter 'PASeasy-PTA-syslog-ca-*.pem')[0]
        $oldHash=(Get-FileHash $old.FullName).Hash
        # Additional PEM whitespace is a distinct reviewed bundle without needing another private key.
        $bytes=[Text.Encoding]::ASCII.GetBytes(([Text.Encoding]::ASCII.GetString($publicCert)+"`n"))
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$script:settings.TrustBundleSHA256=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
        $script:settings.TrustBundleBase64=[Convert]::ToBase64String($bytes)
        $null=& $syslog -Settings $script:settings
        (Get-FileHash $old.FullName).Hash|Should -BeExactly $oldHash
        @(Get-ChildItem (Join-Path $script:syslogRoot 'Conf') -Filter 'PASeasy-PTA-syslog-ca-*.pem').Count|Should -Be 2
        (Get-Content $script:dbparm -Raw)|Should -Match ([regex]::Escape($script:settings.TrustBundleSHA256.ToLowerInvariant()+'.pem'))
    }
}
