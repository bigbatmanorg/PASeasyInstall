BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1'); Import-PASTestModule
}
Describe 'Engine authenticated-step boundaries (transport fixtures, no vendor execution)' {
    BeforeEach {
        $base=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));New-Item $base -ItemType Directory|Out-Null
        $workflowPath=Join-Path $base 'workflow.psd1';$inventoryPath=Join-Path $base 'inventory.psd1';$stateRoot=Join-Path $base 'state'
        [IO.File]::WriteAllText((Join-Path $base 'task.ps1'),'param($Stage) [pscustomobject]@{Changed=$false;Message="fixture"}')
        [IO.File]::WriteAllText((Join-Path $base 'verify.ps1'),'param($Stage) [pscustomobject]@{Passed=$true;Message="fixture"}')
        & (Get-Module PASeasyInstall) {
            param($workflowPath,$inventoryPath)
            $steps=@(
                @{Id='install';Script='task.ps1';Verify='verify.ps1';Inputs=@{Stage='Install'}}
                @{Id='register';Script='task.ps1';Verify='verify.ps1';Mode='Detached';RequiresVaultSession=$true;Inputs=@{Stage='Register'}}
                @{Id='post';Script='task.ps1';Verify='verify.ps1';Inputs=@{Stage='Post'}}
            )
            [IO.File]::WriteAllText($workflowPath,(ConvertTo-PASLiteral @{SchemaVersion=1;Name='Control-plane fixture';Target='fixture';Steps=$steps}))
            [IO.File]::WriteAllText($inventoryPath,(ConvertTo-PASLiteral @{SchemaVersion=1;Targets=@{fixture=@{Protocol='WinRM';Runtime='WindowsPowerShell';ComputerName='192.0.2.40'}};Values=@{}}))
        } $workflowPath $inventoryPath
        $global:PAeasyEngineOperationFixture=@{Held=$false;Entered=0;Released=0;Events=(New-Object System.Collections.ArrayList);FailPost=$false}
        Mock Invoke-PASRemoteLock -ModuleName PASeasyInstall {$false}
        Mock Clear-PASConnections -ModuleName PASeasyInstall {}
        Mock Clear-PASRecoveryTasks -ModuleName PASeasyInstall {}
        Mock Finish-PASDetached -ModuleName PASeasyInstall {}
        Mock Get-PASCheck -ModuleName PASeasyInstall {[pscustomobject]@{Passed=$true;Message='Fixture independent check';Evidence=@()}}
        Mock Get-PASDetachedStatus -ModuleName PASeasyInstall {@{state='Succeeded';workerActive=$false}}
        # The Vault lock is a named mutex (Locks.ps1). The fixture records who holds it.
        Mock Enter-PASVaultLock -ModuleName PASeasyInstall {
            $global:PAeasyEngineOperationFixture.Held|Should -BeFalse
            $global:PAeasyEngineOperationFixture.Held=$true
            $global:PAeasyEngineOperationFixture.Entered++
            return [pscustomobject]@{Address=$Address}
        }
        Mock Exit-PASVaultLock -ModuleName PASeasyInstall {
            if($null -eq $Lock){return}
            $global:PAeasyEngineOperationFixture.Held=$false
            $global:PAeasyEngineOperationFixture.Released++
        }
        Mock Initialize-PASDetached -ModuleName PASeasyInstall {
            $global:PAeasyEngineOperationFixture.Held|Should -BeTrue
            [void]$global:PAeasyEngineOperationFixture.Events.Add('RegisterLaunched')
        }
        Mock Wait-PASDetached -ModuleName PASeasyInstall {@{state='Succeeded';changed=$false;data=@{};message='Fixture completed'}}
        Mock Invoke-PASAdapterScript -ModuleName PASeasyInstall {
            $global:PAeasyEngineOperationFixture.Held|Should -BeFalse
            [void]$global:PAeasyEngineOperationFixture.Events.Add([string]$Parameters.Stage)
            if($Parameters.Stage -eq 'Post' -and $global:PAeasyEngineOperationFixture.FailPost){return @{Ok=$false;Error='Fixture post-install failure';Output='';Terminal=$null}}
            @{Ok=$true;Terminal=@{Changed=$false;Message='Fixture completed';Data=@{}};Output=''}
        }
    }
    It 'admits only registration, leaving independent OS installation and post-install outside the Vault lock' {
        $result=& (Get-Module PASeasyInstall) {
            param($wf,$inv,$state)
            Invoke-PASWorkflow -WorkflowPath $wf -InventoryPath $inv -StateRoot $state -RunId scope001 -VaultAddress 192.0.2.99 -Quiet
        } $workflowPath $inventoryPath $stateRoot
        $result.Status|Should -BeExactly Succeeded
        @($global:PAeasyEngineOperationFixture.Events.ToArray())|Should -Be @('Install','RegisterLaunched','Post')
        $global:PAeasyEngineOperationFixture.Entered|Should -Be 1
        $global:PAeasyEngineOperationFixture.Released|Should -Be 1
        $global:PAeasyEngineOperationFixture.Held|Should -BeFalse
        Should -Invoke Enter-PASVaultLock -ModuleName PASeasyInstall -Times 1
    }
    It 'releases a completed registration even when a later OS step fails and does not repeat registration on recovery' {
        $global:PAeasyEngineOperationFixture.FailPost=$true
        {& (Get-Module PASeasyInstall) {
            param($wf,$inv,$state)
            Invoke-PASWorkflow $wf $inv -StateRoot $state -RunId scope002 -VaultAddress 192.0.2.99 -Quiet
        } $workflowPath $inventoryPath $stateRoot}|Should -Throw '*Fixture post-install failure*'
        $global:PAeasyEngineOperationFixture.Held|Should -BeFalse
        $global:PAeasyEngineOperationFixture.FailPost=$false
        & (Get-Module PASeasyInstall) {
            param($wf,$inv,$state)
            Invoke-PASWorkflow $wf $inv -StateRoot $state -RunId scope002 -VaultAddress 192.0.2.99 -Resume -Retry post -Quiet
        } $workflowPath $inventoryPath $stateRoot|Out-Null
        Should -Invoke Initialize-PASDetached -ModuleName PASeasyInstall -Times 1
        $global:PAeasyEngineOperationFixture.Held|Should -BeFalse
    }
    It 'releases the Vault lock after an uncertain registration and reconciles the same attempt without another launch' {
        Mock Wait-PASDetached -ModuleName PASeasyInstall {throw 'PAExecUnknown: fixture transport lost'}
        {& (Get-Module PASeasyInstall) {
            param($wf,$inv,$state)
            Invoke-PASWorkflow $wf $inv -StateRoot $state -RunId scope003 -VaultAddress 192.0.2.99 -Quiet
        } $workflowPath $inventoryPath $stateRoot}|Should -Throw '*fixture transport lost*'
        $global:PAeasyEngineOperationFixture.Held|Should -BeFalse
        $before=Get-Content (Join-Path $stateRoot 'scope003/fixture/state.json') -Raw|ConvertFrom-Json
        Mock Wait-PASDetached -ModuleName PASeasyInstall {@{state='Succeeded';changed=$false;data=@{};message='Same fixture attempt completed'}}
        & (Get-Module PASeasyInstall) {
            param($wf,$inv,$state)
            Invoke-PASWorkflow $wf $inv -StateRoot $state -RunId scope003 -VaultAddress 192.0.2.99 -Resume -Quiet
        } $workflowPath $inventoryPath $stateRoot|Out-Null
        $after=Get-Content (Join-Path $stateRoot 'scope003/fixture/state.json') -Raw|ConvertFrom-Json
        $after.steps.register.attemptId|Should -BeExactly $before.steps.register.attemptId
        Should -Invoke Initialize-PASDetached -ModuleName PASeasyInstall -Times 1
        $global:PAeasyEngineOperationFixture.Held|Should -BeFalse
    }
    It 'does not treat <RemoteState> as proof a dispatched registration never ran' -TestCases @(@{RemoteState='Missing'},@{RemoteState='NotStarted'}) {
        param($RemoteState)
        Mock Wait-PASDetached -ModuleName PASeasyInstall {throw 'PAExecUnknown: synthetic lost controller acknowledgement'}
        {& (Get-Module PASeasyInstall) {
            param($wf,$inv,$state)
            Invoke-PASWorkflow $wf $inv -StateRoot $state -RunId scope004 -VaultAddress 192.0.2.99 -Quiet
        } $workflowPath $inventoryPath $stateRoot}|Should -Throw '*PAExecUnknown*'
        # Model the last journal write before a controller power loss. This is
        # synthetic test state, never a product journal or manufactured success.
        $path=Join-Path $stateRoot 'scope004/fixture/state.json'
        $journal=Get-Content $path -Raw|ConvertFrom-Json
        $journal.steps.register.status='Dispatched'
        $journal|ConvertTo-Json -Depth 40|Set-Content $path
        $global:PAeasyEngineOperationFixture.RemoteState=$RemoteState
        Mock Wait-PASDetached -ModuleName PASeasyInstall {@{state=$global:PAeasyEngineOperationFixture.RemoteState}}
        {& (Get-Module PASeasyInstall) {
            param($wf,$inv,$state)
            Invoke-PASWorkflow $wf $inv -StateRoot $state -RunId scope004 -VaultAddress 192.0.2.99 -Resume -Quiet
        } $workflowPath $inventoryPath $stateRoot}|Should -Throw ('*Unknown*'+$RemoteState+'*')
        Should -Invoke Initialize-PASDetached -ModuleName PASeasyInstall -Times 1
        $global:PAeasyEngineOperationFixture.Held|Should -BeFalse
    }
}
AfterAll {Remove-Variable -Name PAeasyEngineOperationFixture -Scope Global -ErrorAction SilentlyContinue}
