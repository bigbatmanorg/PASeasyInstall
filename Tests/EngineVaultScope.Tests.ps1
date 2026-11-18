BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Engine authenticated-step boundaries (transport fixtures, no vendor execution)' {
    BeforeEach {
        $base=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));New-Item $base -ItemType Directory|Out-Null
        $workflowPath=Join-Path $base 'workflow.psd1';$inventoryPath=Join-Path $base 'inventory.psd1';$stateRoot=Join-Path $base 'state'
        [IO.File]::WriteAllText((Join-Path $base 'task.ps1'),'param($Stage) [pscustomobject]@{Changed=$false;Message="fixture"}')
        [IO.File]::WriteAllText((Join-Path $base 'verify.ps1'),'param($Stage) [pscustomobject]@{Passed=$true;Message="fixture"}')
        & (Get-Module PASeasyInstall.Core) {
            param($workflowPath,$inventoryPath)
            $steps=@(
                @{Id='install';Script='task.ps1';Verify='verify.ps1';Inputs=@{Stage='Install'}}
                @{Id='register';Script='task.ps1';Verify='verify.ps1';Mode='Detached';RequiresVaultSession=$true;Inputs=@{Stage='Register'}}
                @{Id='post';Script='task.ps1';Verify='verify.ps1';Inputs=@{Stage='Post'}}
            )
            [IO.File]::WriteAllText($workflowPath,(ConvertTo-PASLiteral @{SchemaVersion=1;Name='Control-plane fixture';Target='fixture';Steps=$steps}))
            [IO.File]::WriteAllText($inventoryPath,(ConvertTo-PASLiteral @{SchemaVersion=1;Targets=@{fixture=@{Protocol='WinRM';Runtime='WindowsPowerShell';ComputerName='192.0.2.40'}};Values=@{}}))
        } $workflowPath $inventoryPath
        $global:PAeasyEngineOperationFixture=@{Held=$false;PriorClaim=$false;Gates=(New-Object System.Collections.ArrayList);Events=(New-Object System.Collections.ArrayList);FailPost=$false}
        Mock Invoke-PSRemoteLock -ModuleName PASeasyInstall.Core {$false}
        Mock Clear-PSConnections -ModuleName PASeasyInstall.Core {}
        Mock Clear-PSRecoveryTasks -ModuleName PASeasyInstall.Core {}
        Mock Finish-PSDetached -ModuleName PASeasyInstall.Core {}
        Mock Get-PSCheck -ModuleName PASeasyInstall.Core {[pscustomobject]@{Passed=$true;Message='Fixture independent check';Evidence=@()}}
        Mock Get-PSDetachedStatus -ModuleName PASeasyInstall.Core {@{state='Succeeded';workerActive=$false}}
        Mock Enter-PASeasyVaultOperation -ModuleName PASeasyInstall.Core {
            $global:PAeasyEngineOperationFixture.Held|Should -BeFalse
            $global:PAeasyEngineOperationFixture.Held=$true
            $gate=[pscustomobject]@{Completed=$false;Disposed=$false;PreexistingClaim=$global:PAeasyEngineOperationFixture.PriorClaim}
            $gate|Add-Member ScriptMethod Complete {$this.Completed=$true}
            $gate|Add-Member ScriptMethod Dispose {
                $this.Disposed=$true
                $global:PAeasyEngineOperationFixture.Held=$false
                $global:PAeasyEngineOperationFixture.PriorClaim=(-not $this.Completed)
            }
            [void]$global:PAeasyEngineOperationFixture.Gates.Add($gate)
            return $gate
        }
        Mock Initialize-PSDetached -ModuleName PASeasyInstall.Core {
            $global:PAeasyEngineOperationFixture.Held|Should -BeTrue
            [void]$global:PAeasyEngineOperationFixture.Events.Add('RegisterLaunched')
        }
        Mock Wait-PSDetached -ModuleName PASeasyInstall.Core {@{state='Succeeded';changed=$false;data=@{};message='Fixture completed'}}
        Mock Invoke-PSAdapterScript -ModuleName PASeasyInstall.Core {
            $global:PAeasyEngineOperationFixture.Held|Should -BeFalse
            [void]$global:PAeasyEngineOperationFixture.Events.Add([string]$Parameters.Stage)
            if($Parameters.Stage -eq 'Post' -and $global:PAeasyEngineOperationFixture.FailPost){return @{Ok=$false;Error='Fixture post-install failure';Output='';Terminal=$null}}
            @{Ok=$true;Terminal=@{Changed=$false;Message='Fixture completed';Data=@{}};Output=''}
        }
    }
    It 'admits only registration, leaving independent OS installation and post-install outside the Vault gate' {
        $result=& (Get-Module PASeasyInstall.Core) {
            param($wf,$inv,$state)
            Invoke-PAExecRun -WorkflowPath $wf -InventoryPath $inv -StateRoot $state -RunId scope001 -VaultSessionAddress 192.0.2.99 -CoordinationDataRoot $state -Quiet
        } $workflowPath $inventoryPath $stateRoot
        $result.Status|Should -BeExactly Succeeded
        @($global:PAeasyEngineOperationFixture.Events.ToArray())|Should -Be @('Install','RegisterLaunched','Post')
        $global:PAeasyEngineOperationFixture.Gates.Count|Should -Be 1
        $global:PAeasyEngineOperationFixture.Gates[0].Completed|Should -BeTrue
        $global:PAeasyEngineOperationFixture.Gates[0].Disposed|Should -BeTrue
        Should -Invoke Enter-PASeasyVaultOperation -ModuleName PASeasyInstall.Core -Times 1
    }
    It 'releases a completed registration even when a later OS step fails and does not repeat registration on recovery' {
        $global:PAeasyEngineOperationFixture.FailPost=$true
        {& (Get-Module PASeasyInstall.Core) {
            param($wf,$inv,$state)
            Invoke-PAExecRun $wf $inv -StateRoot $state -RunId scope002 -VaultSessionAddress 192.0.2.99 -CoordinationDataRoot $state -Quiet
        } $workflowPath $inventoryPath $stateRoot}|Should -Throw '*Fixture post-install failure*'
        $global:PAeasyEngineOperationFixture.PriorClaim|Should -BeFalse
        $global:PAeasyEngineOperationFixture.FailPost=$false
        & (Get-Module PASeasyInstall.Core) {
            param($wf,$inv,$state)
            Invoke-PAExecRun $wf $inv -StateRoot $state -RunId scope002 -VaultSessionAddress 192.0.2.99 -CoordinationDataRoot $state -Resume -Retry post -Quiet
        } $workflowPath $inventoryPath $stateRoot|Out-Null
        Should -Invoke Initialize-PSDetached -ModuleName PASeasyInstall.Core -Times 1
        $global:PAeasyEngineOperationFixture.PriorClaim|Should -BeFalse
    }
    It 'retains an uncertain registration claim and reconciles the same attempt without another launch' {
        Mock Wait-PSDetached -ModuleName PASeasyInstall.Core {throw 'PAExecUnknown: fixture transport lost'}
        {& (Get-Module PASeasyInstall.Core) {
            param($wf,$inv,$state)
            Invoke-PAExecRun $wf $inv -StateRoot $state -RunId scope003 -VaultSessionAddress 192.0.2.99 -CoordinationDataRoot $state -Quiet
        } $workflowPath $inventoryPath $stateRoot}|Should -Throw '*fixture transport lost*'
        $global:PAeasyEngineOperationFixture.PriorClaim|Should -BeTrue
        $before=Get-Content (Join-Path $stateRoot 'scope003/fixture/state.json') -Raw|ConvertFrom-Json
        Mock Wait-PSDetached -ModuleName PASeasyInstall.Core {@{state='Succeeded';changed=$false;data=@{};message='Same fixture attempt completed'}}
        & (Get-Module PASeasyInstall.Core) {
            param($wf,$inv,$state)
            Invoke-PAExecRun $wf $inv -StateRoot $state -RunId scope003 -VaultSessionAddress 192.0.2.99 -CoordinationDataRoot $state -Resume -Quiet
        } $workflowPath $inventoryPath $stateRoot|Out-Null
        $after=Get-Content (Join-Path $stateRoot 'scope003/fixture/state.json') -Raw|ConvertFrom-Json
        $after.steps.register.attemptId|Should -BeExactly $before.steps.register.attemptId
        Should -Invoke Initialize-PSDetached -ModuleName PASeasyInstall.Core -Times 1
        $global:PAeasyEngineOperationFixture.PriorClaim|Should -BeFalse
    }
    It 'does not treat <RemoteState> as proof a dispatched registration never ran' -TestCases @(@{RemoteState='Missing'},@{RemoteState='NotStarted'}) {
        param($RemoteState)
        Mock Wait-PSDetached -ModuleName PASeasyInstall.Core {throw 'PAExecUnknown: synthetic lost controller acknowledgement'}
        {& (Get-Module PASeasyInstall.Core) {
            param($wf,$inv,$state)
            Invoke-PAExecRun $wf $inv -StateRoot $state -RunId scope004 -VaultSessionAddress 192.0.2.99 -CoordinationDataRoot $state -Quiet
        } $workflowPath $inventoryPath $stateRoot}|Should -Throw '*PAExecUnknown*'
        # Model the last journal write before a controller power loss. This is
        # synthetic test state, never a product journal or manufactured success.
        $path=Join-Path $stateRoot 'scope004/fixture/state.json'
        $journal=Get-Content $path -Raw|ConvertFrom-Json
        $journal.steps.register.status='Dispatched'
        $journal|ConvertTo-Json -Depth 40|Set-Content $path
        $global:PAeasyEngineOperationFixture.RemoteState=$RemoteState
        Mock Wait-PSDetached -ModuleName PASeasyInstall.Core {@{state=$global:PAeasyEngineOperationFixture.RemoteState}}
        {& (Get-Module PASeasyInstall.Core) {
            param($wf,$inv,$state)
            Invoke-PAExecRun $wf $inv -StateRoot $state -RunId scope004 -VaultSessionAddress 192.0.2.99 -CoordinationDataRoot $state -Resume -Quiet
        } $workflowPath $inventoryPath $stateRoot}|Should -Throw ('*Unknown*'+$RemoteState+'*')
        Should -Invoke Initialize-PSDetached -ModuleName PASeasyInstall.Core -Times 1
        $global:PAeasyEngineOperationFixture.PriorClaim|Should -BeTrue
    }
}
AfterAll {Remove-Variable -Name PAeasyEngineOperationFixture -Scope Global -ErrorAction SilentlyContinue}
