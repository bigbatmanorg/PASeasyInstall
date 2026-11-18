BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Typed independent check task transport' {
    BeforeAll {
        $hostPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/Private/Engine/Assets/TaskHost.ps1'
        $savedTemp=$env:TEMP;if(-not $env:TEMP){$env:TEMP=[IO.Path]::GetTempPath()}
    }
    AfterAll {$env:TEMP=$savedTemp}
    It 'keeps an actual false check distinct from a failed process and redacts secret evidence' {
        $result=& $hostPath -Contract Check -Parameters @{AdminPassword='synthetic-check-marker-941'} -Code 'param($AdminPassword) [pscustomobject]@{Passed=$false;Evidence=@($AdminPassword);Message=$AdminPassword;SessionClosed=$true}'
        $result.Ok|Should -BeTrue
        $result.Check.passed|Should -BeFalse
        $result.Check.sessionClosed|Should -BeTrue
        ($result|ConvertTo-Json -Depth 15 -Compress)|Should -Not -Match 'synthetic-check-marker-941'
        $result.Check.evidence[0]|Should -BeExactly '[REDACTED]'
    }
    It 'refuses missing or string acceptance flags and unbounded evidence' {
        foreach($code in @('[pscustomobject]@{Message="missing"}','[pscustomobject]@{Passed="false"}','[pscustomobject]@{Passed=$true;SessionClosed="True"}','[pscustomobject]@{Passed=$true;Evidence=@(("x"*2049))}','[pscustomobject]@{Passed=$true;Evidence=@(1..33|ForEach-Object {"entry"})}')){
            $result=& $hostPath -Contract Check -Parameters @{} -Code $code
            $result.Ok|Should -BeFalse
        }
    }
    It 'does not turn a structured result followed by a nonzero native exit into success' {
        foreach($contract in @('Object','Check')){
            $result=& $hostPath -Contract $contract -Parameters @{} -Code '[pscustomobject]@{Changed=$false;Passed=$true}; exit 9'
            $result.Ok|Should -BeFalse
            $result.ExitCode|Should -Be 9
        }
    }
}
Describe 'Durable verifier attempt generations' {
    InModuleScope PASeasyInstall.Core {
        BeforeEach {
            $base=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));New-Item $base -ItemType Directory|Out-Null
            [IO.File]::WriteAllText((Join-Path $base 'verify.ps1'),'param($AdminPassword) [pscustomobject]@{Passed=$true;SessionClosed=$true;Evidence=@()}')
            $plan=[pscustomobject]@{Root=$base;Target=@{Protocol='WinRM';Runtime='WindowsPowerShell';ComputerName='192.0.2.18'}}
            $step=@{Id='health';Verify='verify.ps1';VerifyMode='Detached';VerifyRequiresVaultSession=$true}
            $current=@{status='Verifying';actionAcknowledged=$true}
            $context=@{RunDirectory=$base;State=@{steps=@{health=$current}};Redactions=@('synthetic-check-password');VaultAdmitted=$true;Seq=0;Echo=$false;RunId='check001';TargetName='fixture'}
            $script:CheckFixture=@{Events=[Collections.Generic.List[string]]::new();FailStage=$false;RemoteState='Succeeded';Passed=$true;Closed=$true;Active=$false}
            Mock Finish-PSDetached {}
            Mock Initialize-PSDetached {
                param($Target,$Credentials,$ScriptPath,$Parameters,$AttemptId,$TimeoutSeconds,$Contract)
                $journal=Read-PSJson (Join-Path $context.RunDirectory 'state.json')
                $journal.steps.health.check.attemptId|Should -BeExactly $AttemptId
                $journal.steps.health.check.status|Should -BeExactly Dispatched
                $Contract|Should -BeExactly Check
                $Parameters.Keys|Should -Not -Contain UnusedSecret
                $script:CheckFixture.Events.Add('Initialize:'+ $AttemptId)
                if($script:CheckFixture.FailStage){throw 'injected initializer observation loss'}
            }
            Mock Wait-PSDetached {
                param($Target,$Credentials,$AttemptId)
                $script:CheckFixture.Events.Add('Observe:'+ $AttemptId)
                return @{state=$script:CheckFixture.RemoteState;attemptId=$AttemptId;check=@{schemaVersion=1;passed=$script:CheckFixture.Passed;sessionClosed=$script:CheckFixture.Closed;message='checked';evidence=@('identity and logout checked')}}
            }
            Mock Wait-PSDetachedSessionQuiescence {
                param($Target,$Credentials,$AttemptId)
                $script:CheckFixture.Events.Add('Quiescent:'+ $AttemptId)
                if($script:CheckFixture.Active){throw 'PAExecUnknown: worker exit unconfirmed'}
            }
        }
        It 'journals before dispatch and reconciles an unconsumed success without another launch' {
            $result=Get-PAExecDurableCheck $plan $step @{} @{AdminPassword='synthetic-check-password';UnusedSecret='not required'} $current $context
            $result.Passed|Should -BeTrue
            $id=$current.check.attemptId
            $current.check.consumed|Should -BeFalse
            # Simulate controller loss after remote completion but before parent consumption.
            $context.State=Read-PSJson (Join-Path $base 'state.json');$current=$context.State.steps.health
            (Get-PAExecDurableCheck $plan $step @{} @{} $current $context).Passed|Should -BeTrue
            $current.check.attemptId|Should -BeExactly $id
            Should -Invoke Initialize-PSDetached -Times 1 -Exactly
            Complete-PAExecCheckGeneration $current
            $current.status='Succeeded';Save-PSState $context
            $context.State=Read-PSJson (Join-Path $base 'state.json');$current=$context.State.steps.health
            $null=Get-PAExecDurableCheck $plan $step @{} @{} $current $context Revalidation
            $current.check.attemptId|Should -Not -Be $id
            $current.check.previousAttempts|Should -Contain $id
            Should -Invoke Initialize-PSDetached -Times 2 -Exactly
        }
        It 'retains the original dispatch ID after interrupted staging and missing target evidence' {
            $script:CheckFixture.FailStage=$true
            {Get-PAExecDurableCheck $plan $step @{} @{} $current $context}|Should -Throw '*staging interrupted*'
            $id=$current.check.attemptId
            $context.State=Read-PSJson (Join-Path $base 'state.json');$current=$context.State.steps.health
            $script:CheckFixture.RemoteState='Missing'
            {Get-PAExecDurableCheck $plan $step @{} @{} $current $context}|Should -Throw '*same attempt*'
            $current.check.attemptId|Should -BeExactly $id
            $current.check.consumed|Should -BeFalse
            Should -Invoke Initialize-PSDetached -Times 1 -Exactly
        }
        It 'requires worker exit and typed session closure before accepting any authenticated result' {
            $script:CheckFixture.Active=$true
            {Get-PAExecDurableCheck $plan $step @{} @{} $current $context}|Should -Throw '*worker exit*'
            $script:CheckFixture.Active=$false;$script:CheckFixture.Closed='True'
            {Get-PAExecDurableCheck $plan $step @{} @{} $current $context}|Should -Throw '*session closure*'
            $current.check.consumed|Should -BeFalse
            Should -Invoke Initialize-PSDetached -Times 1 -Exactly
        }
        It 'refuses an unauthorised verifier before staging and preserves helper drift as uncertainty' {
            $context.VaultAdmitted=$false
            {Get-PAExecDurableCheck $plan $step @{} @{} $current $context}|Should -Throw '*no admitted Vault lease*'
            Should -Invoke Initialize-PSDetached -Times 0
            $context.VaultAdmitted=$true
            $null=Get-PAExecDurableCheck $plan $step @{} @{} $current $context
            [IO.File]::AppendAllText((Join-Path $base 'verify.ps1'),' # changed')
            {Get-PAExecDurableCheck $plan $step @{} @{} $current $context}|Should -Throw '*script changed*'
            Should -Invoke Initialize-PSDetached -Times 1 -Exactly
        }
        It 'waits for the authenticated action worker before starting an independent verifier' {
            $step.RequiresVaultSession=$true;$current.attemptId='0123456789abcdef0123456789abcdef'
            $null=Get-PAExecStepCheck -Plan $plan -Step $step -Credentials @{} -Inputs @{} -Current $current -Context $context -Script verify.ps1
            $script:CheckFixture.Events[0]|Should -BeExactly ('Quiescent:'+$current.attemptId)
            $script:CheckFixture.Events[1]|Should -Match '^Initialize:'
        }
    }
}
Describe 'Engine durable verifier recovery without action replay' {
    BeforeEach {
        $base=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'));New-Item $base -ItemType Directory|Out-Null
        $wf=Join-Path $base 'workflow.psd1';$inv=Join-Path $base 'inventory.psd1';$state=Join-Path $base 'Runs'
        [IO.File]::WriteAllText((Join-Path $base 'task.ps1'),'param(); [pscustomobject]@{Changed=$false}')
        [IO.File]::WriteAllText((Join-Path $base 'verify.ps1'),'param(); [pscustomobject]@{Passed=$true;SessionClosed=$true}')
        [IO.File]::WriteAllText($wf,"@{SchemaVersion=1;Name='fixture';Target='fixture';Steps=@(@{Id='install';Script='task.ps1';Verify='verify.ps1';VerifyMode='Detached';VerifyRequiresVaultSession=`$true;TimeoutSeconds=23})}")
        [IO.File]::WriteAllText($inv,"@{SchemaVersion=1;Targets=@{fixture=@{Protocol='WinRM';Runtime='WindowsPowerShell';ComputerName='192.0.2.18'}}}")
        $global:PAEasyDurableEngine=@{Passed=$false;FailObserve=$false;ActionCount=0;CheckIds=[Collections.Generic.List[string]]::new();Timeouts=[Collections.Generic.List[int]]::new();Gates=[Collections.Generic.List[object]]::new()}
        Mock Invoke-PSRemoteLock -ModuleName PASeasyInstall.Core {$false}
        Mock Clear-PSConnections -ModuleName PASeasyInstall.Core {}
        Mock Clear-PSRecoveryTasks -ModuleName PASeasyInstall.Core {}
        Mock Finish-PSDetached -ModuleName PASeasyInstall.Core {}
        Mock Wait-PSDetachedSessionQuiescence -ModuleName PASeasyInstall.Core {}
        Mock Enter-PASeasyVaultOperation -ModuleName PASeasyInstall.Core {
            $gate=[pscustomobject]@{Completed=$false;Disposed=$false;PreexistingClaim=$false}
            $gate|Add-Member ScriptMethod Complete {$this.Completed=$true}
            $gate|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
            $global:PAEasyDurableEngine.Gates.Add($gate);return $gate
        }
        Mock Invoke-PSAdapterScript -ModuleName PASeasyInstall.Core {$global:PAEasyDurableEngine.ActionCount++;return @{Ok=$true;Terminal=@{Changed=$false};Output=''}}
        Mock Initialize-PSDetached -ModuleName PASeasyInstall.Core {param($AttemptId,$TimeoutSeconds) $global:PAEasyDurableEngine.CheckIds.Add($AttemptId);$global:PAEasyDurableEngine.Timeouts.Add($TimeoutSeconds)}
        Mock Wait-PSDetached -ModuleName PASeasyInstall.Core {param($AttemptId,$TimeoutSeconds) $global:PAEasyDurableEngine.Timeouts.Add($TimeoutSeconds);if($global:PAEasyDurableEngine.FailObserve){throw 'fixture observation loss'};return @{state='Succeeded';attemptId=$AttemptId;check=@{schemaVersion=1;passed=$global:PAEasyDurableEngine.Passed;sessionClosed=$true;evidence=@();message='independent check'}}}
    }
    AfterEach {Remove-Variable PAEasyDurableEngine -Scope Global -ErrorAction SilentlyContinue}
    It 'commits a negative check with the acknowledged action, then only reruns independent verification' {
        {& (Get-Module PASeasyInstall.Core) {param($w,$i,$s) Invoke-PAExecRun $w $i -StateRoot $s -RunId durable001 -VaultSessionAddress 192.0.2.99 -CoordinationDataRoot $s -Quiet} $wf $inv $state}|Should -Throw '*Verification failed*'
        $journal=Get-Content (Join-Path $state 'durable001/fixture/state.json') -Raw|ConvertFrom-Json
        $journal.steps.install.actionAcknowledged|Should -BeTrue
        $journal.steps.install.status|Should -BeExactly Failed
        $journal.steps.install.check.consumed|Should -BeTrue
        $actionId=$journal.steps.install.attemptId
        $oldCheck=$journal.steps.install.check.attemptId
        $global:PAEasyDurableEngine.Gates[0].Completed|Should -BeFalse
        $global:PAEasyDurableEngine.Passed=$true
        $result=& (Get-Module PASeasyInstall.Core) {param($w,$i,$s) Invoke-PAExecRun $w $i -StateRoot $s -RunId durable001 -VaultSessionAddress 192.0.2.99 -CoordinationDataRoot $s -Resume -Quiet} $wf $inv $state
        $result.Status|Should -BeExactly Succeeded
        $global:PAEasyDurableEngine.ActionCount|Should -Be 1
        $journal=Get-Content (Join-Path $state 'durable001/fixture/state.json') -Raw|ConvertFrom-Json
        $journal.steps.install.attemptId|Should -BeExactly $actionId
        $journal.steps.install.check.attemptId|Should -Not -Be $oldCheck
        $global:PAEasyDurableEngine.Gates[1].Completed|Should -BeTrue
        $null=& (Get-Module PASeasyInstall.Core) {param($w,$i,$s) Invoke-PAExecRun $w $i -StateRoot $s -RunId durable001 -VaultSessionAddress 192.0.2.99 -CoordinationDataRoot $s -Resume -Quiet} $wf $inv $state
        $global:PAEasyDurableEngine.ActionCount|Should -Be 1
        @($global:PAEasyDurableEngine.Timeouts)|Should -Be @(23,23,23,23,23,23)
    }
    It 'does not let explicit Retry bypass an outstanding verifier and relaunch its action' {
        $global:PAEasyDurableEngine.FailObserve=$true
        {& (Get-Module PASeasyInstall.Core) {param($w,$i,$s) Invoke-PAExecRun $w $i -StateRoot $s -RunId durable002 -VaultSessionAddress 192.0.2.99 -CoordinationDataRoot $s -Quiet} $wf $inv $state}|Should -Throw '*observation loss*'
        $before=Get-Content (Join-Path $state 'durable002/fixture/state.json') -Raw|ConvertFrom-Json
        {& (Get-Module PASeasyInstall.Core) {param($w,$i,$s) Invoke-PAExecRun $w $i -StateRoot $s -RunId durable002 -VaultSessionAddress 192.0.2.99 -CoordinationDataRoot $s -Resume -Retry install -Quiet} $wf $inv $state}|Should -Throw '*unconsumed durable verifier*'
        $after=Get-Content (Join-Path $state 'durable002/fixture/state.json') -Raw|ConvertFrom-Json
        $after.steps.install.check.attemptId|Should -BeExactly $before.steps.install.check.attemptId
        $global:PAEasyDurableEngine.ActionCount|Should -Be 1
        $global:PAEasyDurableEngine.CheckIds.Count|Should -Be 1
    }
    It 'rejects a skipping probe on an authenticated action before dispatch' {
        [IO.File]::WriteAllText($wf,"@{SchemaVersion=1;Name='unsafe';Target='fixture';Steps=@(@{Id='register';Script='task.ps1';Mode='Detached';RequiresVaultSession=`$true;Verify='verify.ps1';Probe='verify.ps1'})}")
        {& (Get-Module PASeasyInstall.Core) {param($w,$i) Get-PAExecPlan $w $i} $wf $inv}|Should -Throw '*cannot use a skipping direct probe*'
        $global:PAEasyDurableEngine.ActionCount|Should -Be 0
        $global:PAEasyDurableEngine.CheckIds.Count|Should -Be 0
    }
}
Describe 'Borrowed parent Vault lease ownership' {
    InModuleScope PASeasyInstall.Core {
        It 'retains a real parent claim after a child check and rejects nested admission' -Skip:($env:OS -ne 'Windows_NT') {
            $base=Join-Path $TestDrive 'borrowed';New-Item -ItemType Directory $base|Out-Null
            $wf=Join-Path $base 'workflow.psd1';$inv=Join-Path $base 'inventory.psd1'
            [IO.File]::WriteAllText((Join-Path $base 'verify.ps1'),'param();[pscustomobject]@{Passed=$true;SessionClosed=$true}')
            [IO.File]::WriteAllText($wf,"@{SchemaVersion=1;Name='borrowed';Target='fixture';Steps=@(@{Id='health';Kind='Verify';Verify='verify.ps1';VerifyMode='Detached';VerifyRequiresVaultSession=`$true})}")
            [IO.File]::WriteAllText($inv,"@{SchemaVersion=1;Targets=@{fixture=@{Protocol='WinRM';Runtime='WindowsPowerShell';ComputerName='192.0.2.18'}}}")
            Mock Invoke-PSRemoteLock {$false}
            Mock Clear-PSConnections {}
            Mock Clear-PSRecoveryTasks {}
            Mock Initialize-PSDetached {}
            Mock Finish-PSDetached {}
            Mock Wait-PSDetachedSessionQuiescence {}
            Mock Wait-PSDetached {param($AttemptId) return @{state='Succeeded';attemptId=$AttemptId;check=@{schemaVersion=1;passed=$true;sessionClosed=$true;evidence=@();message='fixture'}}}
            $gates=@(Enter-PASeasyVaultOperation -Address 192.0.2.201 -DataRoot $base -RunId borrowed001)
            try{
                $lease=New-PASeasyBorrowedVaultLease -Address 192.0.2.201 -RunId borrowed001 -DataRoot $base -Gates $gates
                (Invoke-PAExecRun $wf $inv -StateRoot (Join-Path $base 'Runs') -RunId borrowed001 -BorrowedVaultLease $lease -Quiet).Status|Should -BeExactly Succeeded
                $gates[0].Completed|Should -BeFalse
                $gates[0].Disposed|Should -BeFalse
                Test-Path -LiteralPath $gates[0].Path|Should -BeTrue
                {Invoke-PAExecRun $wf $inv -StateRoot (Join-Path $base 'Runs') -RunId borrowed001 -BorrowedVaultLease $lease -VaultSessionAddress 192.0.2.201 -CoordinationDataRoot $base -Resume -Quiet}|Should -Throw '*cannot be nested*'
                {Assert-PASeasyBorrowedVaultLease $lease another001}|Should -Throw '*does not belong*'
                $gates[0].Disposed|Should -BeFalse
            }finally{Exit-PASeasyVaultOperation -Gates $gates -Succeeded $true}
            Test-Path -LiteralPath $gates[0].Path|Should -BeFalse
        }
    }
}
