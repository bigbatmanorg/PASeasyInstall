BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1'); Import-PASTestModule; . (Get-PASTestPrivateProxy)
}
Describe 'Frozen installer media identity' {
    It 'detects changed bytes at an unchanged installer path' {
        $c=New-PASConfigurationTemplate -Template ExistingVault -Path (Join-Path $TestDrive 'config.json') -WhatIf
        $path=Join-Path $TestDrive 'installer.zip'; Set-Content $path 'first media bytes'
        $c.components[0].media=$path
        $first=Get-PASDeploymentPlan -Configuration $c -ResolveMedia
        Set-Content $path 'other media bytes'
        $second=Get-PASDeploymentPlan -Configuration $c -ResolveMedia
        $first.ConfigDigest | Should -Be $second.ConfigDigest
        $first.MediaDigest | Should -Not -Be $second.MediaDigest
        $first.MediaResolved | Should -BeTrue
        @($first.Media).Count | Should -Be 1
    }
    It 'refuses a deployable media plan when an installer is missing' {
        $c=New-PASConfigurationTemplate -Template ExistingVault -Path (Join-Path $TestDrive 'missing.json') -WhatIf
        $c.components[0].media=Join-Path $TestDrive 'absent.zip'
        {Get-PASDeploymentPlan -Configuration $c -ResolveMedia} | Should -Throw '*Missing media*'
    }
}
