# Offline tests; tested only when executed on a PowerShell/Pester runtime.
BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force -ErrorAction Stop
}
Describe 'PASeasyInstall public module API' {
    It 'exports only the supported application API and keeps the controller entry private' {
        $expected=@('Initialize-PASController','New-PASConfigurationTemplate','Test-PASConfiguration','Get-PASDeploymentPlan',
            'Start-PASDeployment','Resume-PASDeployment','Get-PASRunRecord','Get-PASRunRecords',
            'Get-PASRunLog','Get-PASLogSource','Get-PASComponentStatus','Test-PASDeploymentStatus','Start-PASeasyUI')
        (((Get-Module PASeasyInstall.Core).ExportedCommands.Keys|Sort-Object) -join ',')|Should -BeExactly (($expected|Sort-Object) -join ',')
        Get-Command Invoke-PASRunController -ErrorAction SilentlyContinue|Should -BeNullOrEmpty
        (& (Get-Module PASeasyInstall.Core) {(Get-Command Invoke-PASRunController -CommandType Function).Name})|Should -BeExactly Invoke-PASRunController
    }
    It 'exports the expected headless commands' {
        foreach($command in @('New-PASConfigurationTemplate','Test-PASConfiguration','Get-PASDeploymentPlan',
            'Start-PASDeployment','Resume-PASDeployment','Get-PASRunRecord','Get-PASRunLog',
            'Test-PASDeploymentStatus')){
            (Get-Command $command -ErrorAction Stop).Source | Should -Be 'PASeasyInstall'
        }
    }
    It 'can generate and plan a Vault-only configuration offline' {
        $config=New-PASConfigurationTemplate -Template Vault -Path (Join-Path $TestDrive 'vault.json') -Force
        $assessment=Test-PASConfiguration -Configuration $config
        $assessment.Valid | Should -BeTrue
        $plan=Get-PASDeploymentPlan -Configuration $config
        @($plan.Items).Count | Should -Be 1
        $plan.Items[0].Type | Should -Be 'Vault'
    }
    It 'produces stable plan hash on repeated canonical JSON reads' {
        $path=Join-Path $TestDrive 'vault2.json'
        New-PASConfigurationTemplate -Template Vault -Path $path -Force | Out-Null
        $first=Get-PASDeploymentPlan -Config $path
        $second=Get-PASDeploymentPlan -Config $path
        $first.ConfigDigest | Should -Be $second.ConfigDigest
    }
    It 'does not accept plaintext passwords in configuration' {
        $config=New-PASConfigurationTemplate -Template Vault -Path (Join-Path $TestDrive 'bad.json') -Force
        $config.password='Example-Passw0rd!'
        (Test-PASConfiguration -Configuration $config).Valid | Should -BeFalse
    }
    It 'refuses a domain controller on a Vault host' {
        $config=New-PASConfigurationTemplate -Template Vault -Path (Join-Path $TestDrive 'ad.json') -Force
        $config.activeDirectory.mode='Create'
        $config.components+=@{id='ad';type='AD';host='vault01';variant='NewForest'}
        (Test-PASConfiguration -Configuration $config).Valid | Should -BeFalse
    }
    It 'rejects unexpected Lab override keys' {
        $config=New-PASConfigurationTemplate -Template Vault -Path (Join-Path $TestDrive 'unsafe.json') -Force
        $config.security.profile='Lab'
        $config.security.overrides=@{'disableAllValidation'=$true}
        (Test-PASConfiguration -Configuration $config).Valid | Should -BeFalse
    }
}

Describe 'Immutable execution source and read-only observations' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
    }
    It 'detects changed recipe bytes in an isolated module copy' {
        $copy=Join-Path $TestDrive 'candidate'
        Copy-Item (Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall') $copy -Recurse
        $digest={ param($root) & (Get-Module PASeasyInstall.Core) {param($r) $previous=$script:PASRoot; try {$script:PASRoot=$r;Get-PASSourceDigest} finally {$script:PASRoot=$previous}} $root }
        $before=& $digest $copy
        Add-Content (Join-Path $copy 'Recipes/WindowsComponent/Task.ps1') "`n# drift regression"
        (& $digest $copy) | Should -Not -Be $before
    }
    It 'does not persist an observed interrupted status' {
        $id=[guid]::NewGuid().ToString('N')
        $dir=Join-Path (Join-Path $TestDrive 'Runs') $id
        New-Item $dir -ItemType Directory -Force | Out-Null
        $path=Join-Path $dir 'run-v2.json'
        @{id=$id;status='Running';controllerPid=2147483647;message='original'} | ConvertTo-Json | Set-Content $path
        $before=[IO.File]::ReadAllText($path)
        (Get-PASRunRecord -RunId $id -DataRoot $TestDrive).status | Should -Be 'Interrupted'
        [IO.File]::ReadAllText($path) | Should -BeExactly $before
    }
}
