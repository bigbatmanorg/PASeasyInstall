BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Frozen installer media identity' {
    It 'detects changed bytes at an unchanged installer path' {
        $c=New-PASeasyConfig -Template ExistingVault -Path (Join-Path $TestDrive 'config.json') -WhatIf
        $path=Join-Path $TestDrive 'installer.zip'; Set-Content $path 'first media bytes'
        $c.components[0].media=$path
        $first=Get-PASeasyPlan -Configuration $c -ResolveMedia
        Set-Content $path 'other media bytes'
        $second=Get-PASeasyPlan -Configuration $c -ResolveMedia
        $first.ConfigDigest | Should -Be $second.ConfigDigest
        $first.MediaDigest | Should -Not -Be $second.MediaDigest
        $first.MediaResolved | Should -BeTrue
        @($first.Media).Count | Should -Be 1
    }
    It 'refuses a deployable media plan when an installer is missing' {
        $c=New-PASeasyConfig -Template ExistingVault -Path (Join-Path $TestDrive 'missing.json') -WhatIf
        $c.components[0].media=Join-Path $TestDrive 'absent.zip'
        {Get-PASeasyPlan -Configuration $c -ResolveMedia} | Should -Throw '*Missing media*'
    }
    It 'freezes the PTA vendor signing key as well as the installer archive' {
        $c=New-PASeasyConfig -Template ExistingVault -Path (Join-Path $TestDrive 'pta.json') -WhatIf
        $archive=Join-Path $TestDrive 'pta.zip';Set-Content $archive 'fixture installer'
        $key=Join-Path $TestDrive 'vendor.key';Set-Content $key 'first fixture public key'
        $part=$c.components[0];$part.id='pta';$part.type='PTA';$part.host='pta01';$part.media=$archive
        $part.options=@{signingKeyFile=$key;signingKeyFingerprint=('A'*40)}
        $first=Get-PASeasyPlan -Configuration $c -ResolveMedia
        @($first.Media).Count | Should -Be 2
        Set-Content $key 'changed fixture public key'
        (Get-PASeasyPlan -Configuration $c -ResolveMedia).MediaDigest | Should -Not -Be $first.MediaDigest
    }

}
