BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.UI/Legacy/Credentials.ps1')
}
Describe 'PTA certificate planning and protected secret resolution (no vendor execution)' {
    BeforeEach {
        $config=New-PASeasyConfig -Template FullLab -Path (Join-Path $TestDrive 'sample.json') -WhatIf
        $config.components=@($config.components|Where-Object type -eq PTA);$config.vault.existing=$true
        $part=$config.components[0]
        $media=Join-Path $TestDrive 'media.zip';$key=Join-Path $TestDrive 'key.asc';$pfx=Join-Path $TestDrive 'input.pfx'
        [IO.File]::WriteAllText($media,'synthetic ZIP');[IO.File]::WriteAllText($key,'synthetic public key')
        [IO.File]::WriteAllText($pfx,'SYNTHETIC_PRIVATE_CONTAINER_BYTES')
        $part.media=$media;$part.options=@{signingKeyFile=$key;signingKeyFingerprint=('A'*40);certificatePfxFile=$pfx;certificatePfxSHA256=(Get-FileHash $pfx).Hash;ptaName='pta.example.test'}
    }
    It 'freezes private container bytes without transferring them as a persistent media file' {
        $plan=Get-PASeasyPlan -Configuration $config -ResolveMedia
        @($plan.Media|Where-Object Path -eq $pfx).Count|Should -Be 1
        $wf=& (Get-Module PASeasyInstall.Core) {param($p,$c,$d) New-PASeasyComponentWorkflow $p $c $d} $part $config $TestDrive
        $steps=(Import-PowerShellDataFile $wf).Steps;$ids=@($steps|ForEach-Object Id)
        [array]::IndexOf($ids,'install')|Should -BeLessThan ([array]::IndexOf($ids,'configuretls'))
        [array]::IndexOf($ids,'configuretls')|Should -BeLessThan ([array]::IndexOf($ids,'register'))
        $tls=@($steps|Where-Object Id -eq configuretls)[0]
        $tls.Mode|Should -BeExactly Detached;$tls.Inputs.CertificatePfxData.SecretRef|Should -BeExactly PTACertificatePfxData_pta
        $tls.Inputs.CertificatePassword.SecretRef|Should -BeExactly PTACertificatePassword
        @($steps|Where-Object {$_.Kind -eq 'Transfer' -and $_.Destination -like '*.pfx'}).Count|Should -Be 0
        ($plan|ConvertTo-Json -Depth 40)|Should -Not -Match 'SYNTHETIC_PRIVATE_CONTAINER_BYTES'
        $inventory=& (Get-Module PASeasyInstall.Core) {param($c) New-PASeasyRuntimeInventory -Config $c -RunDirectory '' -SkipMediaHash} $config
        $inventory.Values.Components.pta.PTAName|Should -BeExactly pta.example.test
        $inventory.Values.Components.pta.PTACertificatePfxSHA256|Should -BeExactly $part.options.certificatePfxSHA256
        ($inventory|ConvertTo-Json -Depth 40)|Should -Not -Match 'SYNTHETIC_PRIVATE_CONTAINER_BYTES|PTACertificatePassword'
    }
    It 'checks approved bytes again and creates only an in-memory SecureString for the selected component' {
        $secrets=@{PTACertificatePassword=(ConvertTo-SecureString 'synthetic-pfx-password' -AsPlainText -Force)}
        $frozen=@{};$frozen[[IO.Path]::GetFullPath($pfx)]=$part.options.certificatePfxSHA256
        & (Get-Module PASeasyInstall.Core) {param($c,$s,$f) Add-PASeasyPTACertificateSecrets $c $s $f} $config $secrets $frozen
        $secrets.PTACertificatePfxData_pta|Should -BeOfType Security.SecureString
        $secrets.PTACertificatePfxData_pta.IsReadOnly()|Should -BeTrue
        $decoded=[pscredential]::new('fixture',$secrets.PTACertificatePfxData_pta).GetNetworkCredential().Password
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($decoded))|Should -BeExactly SYNTHETIC_PRIVATE_CONTAINER_BYTES
        [IO.File]::WriteAllText($pfx,'changed bytes')
        {& (Get-Module PASeasyInstall.Core) {param($c,$s,$f) Add-PASeasyPTACertificateSecrets $c $s $f} $config $secrets $frozen}|Should -Throw '*changed after plan*'
    }
    It 'refuses unapproved, oversized and passwordless containers before resolving any payload' {
        $secrets=@{}
        {& (Get-Module PASeasyInstall.Core) {param($c,$s) Add-PASeasyPTACertificateSecrets $c $s @{}} $config $secrets}|Should -Throw '*not frozen*'
        $frozen=@{};$frozen[[IO.Path]::GetFullPath($pfx)]=$part.options.certificatePfxSHA256
        {& (Get-Module PASeasyInstall.Core) {param($c,$s,$f) Add-PASeasyPTACertificateSecrets $c $s $f} $config $secrets $frozen}|Should -Throw '*PTACertificatePassword*'
        [IO.File]::WriteAllBytes($pfx,(New-Object byte[] 32769))
        (Test-PASeasyConfig -Configuration $config -CheckMedia).Valid|Should -BeFalse
        {& (Get-Module PASeasyInstall.Core) {param($c,$s,$f) Add-PASeasyPTACertificateSecrets $c $s $f} $config $secrets $frozen}|Should -Throw '*32768*'
        $secrets.ContainsKey('PTACertificatePfxData_pta')|Should -BeFalse
    }
    It 'requires a separate GUI certificate password without exposing PFX bytes to UI state' {
        $path=Join-Path $TestDrive 'ui.json';$config|ConvertTo-Json -Depth 40|Set-Content $path
        $state=@{Auth=(New-PASeasyUICredentialCache)}
        $state.Auth.Secrets.VaultAdmin=ConvertTo-SecureString 'synthetic-admin' -AsPlainText -Force
        $state.Auth.Credentials.vault01=[pscredential]::new('synthetic-primary',(ConvertTo-SecureString 'synthetic-os-password' -AsPlainText -Force))
        {New-PASeasyUICredentials $state $path}|Should -Throw '*PTACertificatePassword*'
        $state.Auth.Secrets.PTACertificatePassword=ConvertTo-SecureString 'synthetic-cert' -AsPlainText -Force
        $auth=New-PASeasyUICredentials $state $path
        $auth.Secrets.ContainsKey('PTACertificatePassword')|Should -BeTrue
        $auth.Secrets.ContainsKey('PTACertificatePfxData_pta')|Should -BeFalse
    }
    It 'allows generated CA only with explicit audited Lab policy and never together with an operator PFX' {
        $config.security.overrides=@{'PTA.GenerateLabCA'=$true}
        (Test-PASeasyConfig -Configuration $config).Valid|Should -BeFalse
        $config.security.profile='Lab'
        (Test-PASeasyConfig -Configuration $config).Valid|Should -BeFalse
        $part.options.Remove('certificatePfxFile');$part.options.Remove('certificatePfxSHA256')
        $assessment=Test-PASeasyConfig -Configuration $config -CheckMedia
        $assessment.Valid|Should -BeTrue;($assessment.Warnings -join ';')|Should -Match 'PTA.GenerateLabCA'
        $inventory=& (Get-Module PASeasyInstall.Core) {param($c) New-PASeasyRuntimeInventory -Config $c -RunDirectory '' -SkipMediaHash} $config
        $inventory.Values.Components.pta.Options.generateLabCA|Should -BeTrue
        $part.options.generateLabCA=$true
        (Test-PASeasyConfig -Configuration $config).Valid|Should -BeFalse
    }
}
