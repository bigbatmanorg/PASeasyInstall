BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Read-only verification recovery (control-plane fixtures)' {
    BeforeEach {
        $base=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));New-Item $base -ItemType Directory|Out-Null
        [IO.File]::WriteAllText((Join-Path $base 'task.ps1'),'param($Stage) [pscustomobject]@{Changed=$true;Message="synthetic action"}')
        [IO.File]::WriteAllText((Join-Path $base 'verify.ps1'),'param($Stage) [pscustomobject]@{Passed=$true;Message="synthetic check"}')
        $wf=Join-Path $base 'workflow.psd1';$inv=Join-Path $base 'inventory.psd1';$state=Join-Path $base 'state'
        & (Get-Module PASeasyInstall.Core) {
            param($wf,$inv)
            [IO.File]::WriteAllText($wf,(ConvertTo-PASLiteral @{SchemaVersion=1;Name='Read-only recovery fixture';Target='fixture';Steps=@(
                @{Id='install';Script='task.ps1';Verify='verify.ps1';Inputs=@{Stage='Install'}}
                @{Id='verify';Kind='Verify';Verify='verify.ps1';Inputs=@{Stage='Verify'}}
            )}))
            [IO.File]::WriteAllText($inv,(ConvertTo-PASLiteral @{SchemaVersion=1;Targets=@{fixture=@{Protocol='Local';Runtime='PowerShell'}};Values=@{}}))
        } $wf $inv
        $global:PAeasyReadOnlyFixturePass=$false
        Mock Invoke-PASRemoteLock -ModuleName PASeasyInstall.Core {$false}
        Mock Clear-PASConnections -ModuleName PASeasyInstall.Core {}
        Mock Clear-PASRecoveryTasks -ModuleName PASeasyInstall.Core {}
        Mock Invoke-PASAdapterScript -ModuleName PASeasyInstall.Core {@{Ok=$true;Terminal=@{Changed=$true;Message='Synthetic install completed';Data=@{}};Output=''}}
        Mock Get-PASCheck -ModuleName PASeasyInstall.Core {
            [pscustomobject]@{Passed=($Inputs.Stage -eq 'Install' -or $global:PAeasyReadOnlyFixturePass);Message='Synthetic independent check';Evidence=@()}
        }
    }
    It 'repeats a failed final check on ordinary resume without replaying the completed install' {
        {& (Get-Module PASeasyInstall.Core) {param($w,$i,$s) Invoke-PASWorkflow $w $i -StateRoot $s -RunId verify001 -Quiet} $wf $inv $state}|Should -Throw '*Verification failed*'
        $before=Get-Content (Join-Path $state 'verify001/fixture/state.json') -Raw|ConvertFrom-Json
        $before.steps.install.status|Should -BeExactly Succeeded
        $before.steps.verify.status|Should -BeExactly Failed
        $global:PAeasyReadOnlyFixturePass=$true
        $result=& (Get-Module PASeasyInstall.Core) {param($w,$i,$s) Invoke-PASWorkflow $w $i -StateRoot $s -RunId verify001 -Resume -Quiet} $wf $inv $state
        $result.Status|Should -BeExactly Succeeded
        $after=Get-Content (Join-Path $state 'verify001/fixture/state.json') -Raw|ConvertFrom-Json
        $after.steps.install.attemptId|Should -BeExactly $before.steps.install.attemptId
        Should -Invoke Invoke-PASAdapterScript -ModuleName PASeasyInstall.Core -Times 1 -ParameterFilter {$Parameters.Stage -eq 'Install'}
        Should -Invoke Invoke-PASAdapterScript -ModuleName PASeasyInstall.Core -Times 0 -ParameterFilter {$Parameters.Stage -eq 'Verify'}
    }
    It 'rejects an action script or Detached mode disguised as a read-only Verify step' {
        & (Get-Module PASeasyInstall.Core) {
            param($path)
            $data=Import-PowerShellDataFile $path;$data.Steps[1].Script='task.ps1'
            [IO.File]::WriteAllText($path,(ConvertTo-PASLiteral $data))
        } $wf
        {& (Get-Module PASeasyInstall.Core) {param($w,$i) Get-PASWorkflowPlan $w $i} $wf $inv}|Should -Throw '*Read-only Verify*'
        & (Get-Module PASeasyInstall.Core) {
            param($path)
            $data=Import-PowerShellDataFile $path;$data.Steps[1].Remove('Script');$data.Steps[1].Mode='Detached'
            [IO.File]::WriteAllText($path,(ConvertTo-PASLiteral $data))
        } $wf
        {& (Get-Module PASeasyInstall.Core) {param($w,$i) Get-PASWorkflowPlan $w $i} $wf $inv}|Should -Throw '*Read-only Verify*'
    }
    It 'generates final component checks without an installer action body' {
        $config=New-PASConfigurationTemplate -Template ExistingVault -Path (Join-Path $base 'config.json') -WhatIf
        $config.components[0].media='synthetic.zip'
        $path=& (Get-Module PASeasyInstall.Core) {param($p,$c,$d) New-PASComponentWorkflow $p $c $d} $config.components[0] $config $base
        $step=@((Import-PowerShellDataFile $path).Steps|Where-Object Id -eq verify)[0]
        $step.Kind|Should -BeExactly Verify;$step.ContainsKey('Script')|Should -BeFalse
        $step.Verify|Should -BeExactly Verify.ps1
    }
}
AfterAll {Remove-Variable PAeasyReadOnlyFixturePass -Scope Global -ErrorAction SilentlyContinue}
