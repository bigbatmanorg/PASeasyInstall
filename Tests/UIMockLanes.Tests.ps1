# The simulated installer of the window (Desktop\Backend\Mock) installs the servers at the same time, the way the
# real installer does: every server works on its own, a registration waits for the Vault and for the first
# PVWA, and only one registration runs at a time.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    $script:savedSeconds = $env:PASUI_MOCK_STAGE_SECONDS
    $env:PASUI_MOCK_STAGE_SECONDS = '1'
    Import-Module (Get-PASTestModulePath 'Desktop/Backend/Mock/PASeasyInstall.Mock.psd1') -Force -ErrorAction Stop
    function New-LaneSteps {
        # A small lab: Vault (3 steps), domain controller, PVWA and PSM on servers of their own.
        $steps = @()
        foreach ($stage in 'ad-install', 'ad-verify') {
            $steps += @{ Id = 'ad'; Type = 'AD'; Host = 'dc01'; Address = '192.0.2.5'; Stage = $stage }
        }
        foreach ($stage in 'prepare', 'install-server', 'verify-primary') {
            $steps += @{ Id = 'vault'; Type = 'Vault'; Host = 'vault01'; Address = '192.0.2.11'; Stage = $stage }
        }
        foreach ($stage in 'install', 'register', 'verify') {
            $steps += @{ Id = 'pvwa01'; Type = 'PVWA'; Host = 'web01'; Address = '192.0.2.21'; Stage = $stage }
        }
        foreach ($stage in 'install', 'register', 'verify') {
            $steps += @{ Id = 'psm01'; Type = 'PSM'; Host = 'psm01'; Address = '192.0.2.31'; Stage = $stage }
        }
        return $steps
    }
    function Get-EventAt {
        param($Timeline, [string]$Component, [string]$Stage, [string]$Event)
        return @($Timeline.Events | Where-Object { $_.Component -eq $Component -and $_.Stage -eq $Stage -and $_.Event -eq $Event })[0].At
    }
}
AfterAll {
    $env:PASUI_MOCK_STAGE_SECONDS = $script:savedSeconds
    # The simulated commands must not stay in front of the real ones for the test files that follow.
    Remove-Module -Name PASeasyInstall.Mock -Force -ErrorAction SilentlyContinue
}

Describe 'Simulated installation of several servers at the same time' {
    It 'starts every server at once and lets the registrations wait for the Vault, one after the other' {
        $steps = New-LaneSteps
        $timeline = InModuleScope PASeasyInstall.Mock -Parameters @{ Steps = $steps } {
            param($Steps)
            New-PASMockLaneTimeline -Steps $Steps -Start 0 -Fail $false -Warn $false
        }
        $timeline.Outcome | Should -Be 'Succeeded'
        # The Vault, PVWA and PSM servers start in the same second.
        Get-EventAt $timeline 'vault' 'prepare' 'TaskStarted' | Should -Be 0
        Get-EventAt $timeline 'pvwa01' 'install' 'TaskStarted' | Should -Be 0
        Get-EventAt $timeline 'psm01' 'install' 'TaskStarted' | Should -Be 0
        # The Vault needs three seconds: PVWA registers then, PSM after PVWA.
        Get-EventAt $timeline 'pvwa01' 'register' 'TaskStarted' | Should -Be 3
        Get-EventAt $timeline 'psm01' 'register' 'TaskStarted' | Should -Be 4
        # Both said that they wait, at the moment their installation was finished.
        Get-EventAt $timeline 'pvwa01' 'register' 'VaultWaiting' | Should -Be 1
        Get-EventAt $timeline 'psm01' 'register' 'VaultWaiting' | Should -Be 1
        $timeline.End | Should -Be 6
        # The events are in the order of their time.
        $times = @($timeline.Events | ForEach-Object { [double]$_.At })
        ($times -join ',') | Should -Be (($times | Sort-Object) -join ',')
    }
    It 'lets a server that joins the new domain wait for the domain controller' {
        $steps = New-LaneSteps
        $timeline = InModuleScope PASeasyInstall.Mock -Parameters @{ Steps = $steps } {
            param($Steps)
            New-PASMockLaneTimeline -Steps $Steps -Start 0 -Fail $false -Warn $false -Joined @('web01')
        }
        # The domain controller needs two seconds.
        Get-EventAt $timeline 'pvwa01' 'install' 'TaskStarted' | Should -Be 2
        Get-EventAt $timeline 'psm01' 'install' 'TaskStarted' | Should -Be 0
    }
    It 'ends the run with the first failure and continues the rest on resume' {
        $steps = New-LaneSteps
        $failed = InModuleScope PASeasyInstall.Mock -Parameters @{ Steps = $steps } {
            param($Steps)
            New-PASMockLaneTimeline -Steps $Steps -Start 0 -Fail $true -Warn $false
        }
        $failed.Outcome | Should -Be 'Failed'
        @($failed.Events | Where-Object { $_.Event -eq 'TaskFailed' }).Count | Should -Be 1
        @($failed.Events | Where-Object { [double]$_.At -gt $failed.End }).Count | Should -Be 0
        $done = @{}
        foreach ($entry in @($failed.Events | Where-Object { $_.Event -eq 'TaskCompleted' })) {
            $done[[string]$entry.Component + '|' + [string]$entry.Stage] = $true
        }
        $resumed = InModuleScope PASeasyInstall.Mock -Parameters @{ Steps = $steps; Done = $done; Start = [double]$failed.End } {
            param($Steps, $Done, $Start)
            New-PASMockLaneTimeline -Steps $Steps -Start $Start -Fail $false -Warn $false -Done $Done
        }
        $resumed.Outcome | Should -Be 'Succeeded'
        # Nothing that was finished is done again.
        @($resumed.Events | Where-Object { $done.ContainsKey([string]$_.Component + '|' + [string]$_.Stage) }).Count | Should -Be 0
        @($resumed.Events | Where-Object { $_.Event -eq 'TaskCompleted' }).Count + $done.Count | Should -Be $steps.Count
    }
}
