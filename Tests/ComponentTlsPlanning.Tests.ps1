BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    . (Get-PASTestPrivateProxy)
}
Describe 'Component HTTPS planning and frozen public trust' {
    BeforeEach {
        $config = New-PASConfigurationTemplate -Template FullLab -Path (Join-Path $TestDrive 'sample.json') -WhatIf
        $config.components = @($config.components | Where-Object { $_.type -in @('PVWA', 'CPM') })
        $config.vault.existing = $true
        $media = Join-Path $TestDrive 'media.zip'
        [IO.File]::WriteAllText($media, 'synthetic media')
        foreach ($part in $config.components) { $part.media = $media }
        $trust = Join-Path $TestDrive 'trust.cer'
        [IO.File]::WriteAllText($trust, 'synthetic public certificate bytes')
        $cpm = @($config.components | Where-Object type -eq CPM)[0]
        $cpm.options.pvwaTrustCertificateFile = $trust
        $cpm.options.pvwaTrustCertificateSHA256 = (Get-FileHash $trust).Hash
    }
    It 'places recoverable TLS after MSI and before authentication and includes both reviewed helpers' {
        foreach ($part in $config.components) {
            $path = & (Get-Module PASeasyInstall) { param(
                    $p,
                    $c,
                    $d
                ) New-PASComponentWorkflow $p $c $d } $part $config $TestDrive
            $workflow = Import-PowerShellDataFile $path
            $ids = @($workflow.Steps | ForEach-Object { $_.Id })
            [array]::IndexOf($ids, 'install') | Should -BeLessThan ([array]::IndexOf($ids, 'configuretls'))
            [array]::IndexOf($ids, 'configuretls') | Should -BeLessThan ([array]::IndexOf($ids, 'register'))
            $tls = @($workflow.Steps | Where-Object Id -eq configuretls)[0]
            $tls.Mode | Should -BeExactly 'Detached'
            $tls.Critical | Should -BeTrue
            $text = [IO.File]::ReadAllText((Join-Path (Split-Path (Split-Path $path)) 'Task.ps1'))
            $text | Should -Match 'function Invoke-PASeasyPvwaTls'
            $text | Should -Match 'function Invoke-PASeasyCpmTls'
            if ($part.type -eq 'CPM') {
                $transfer = @($workflow.Steps | Where-Object Id -eq pvwa-trust-certificate)[0]
                $transfer.Kind | Should -BeExactly 'Transfer'
                $transfer.Destination | Should -BeExactly 'C:\ProgramData\PASeasyInstall\media\cpm\pvwa-trust.cer'
            }
        }
    }
    It 'freezes the public certificate and refuses changed input against its declared pin' {
        $plan = Get-PASDeploymentPlan -Configuration $config -ResolveMedia
        @($plan.Media | Where-Object Path -eq $trust).Count | Should -Be 1
        [IO.File]::WriteAllText($trust, 'changed bytes')
        { Get-PASDeploymentPlan -Configuration $config -ResolveMedia } | Should -Throw '*configured SHA256*'
    }
    It 'admits pinned leaf trust only through an audited Lab Boolean override' {
        $config.security.overrides = @{'CPM.AllowPinnedLeafTrust' = $true }
        (Test-PASConfiguration -Configuration $config).Valid | Should -BeFalse
        $config.security.profile = 'Lab'
        $validated = Test-PASConfiguration -Configuration $config
        $validated.Valid | Should -BeTrue
        ($validated.Warnings -join ';') | Should -Match 'CPM.AllowPinnedLeafTrust'
        $inventory = & (Get-Module PASeasyInstall) { param($c) New-PASRuntimeInventory -Config $c -RunDirectory '' -SkipMediaHash } $config
        $inventory.Values.Components.cpm.AllowPinnedLeafTrust | Should -BeTrue
        $inventory.Values.Components.cpm.PVWATrustCertificateSHA256 | Should -BeExactly $cpm.options.pvwaTrustCertificateSHA256
        $config.security.overrides['CPM.AllowPinnedLeafTrust'] = 'true'
        (Test-PASConfiguration -Configuration $config).Valid | Should -BeFalse
    }
}
