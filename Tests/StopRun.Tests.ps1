# Stop-PASDeployment (public: Stop-PASRun): marks a run Abandoned and lists or releases its target
# locks. Fake run records in a temporary data root; no controller process and no server is involved.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    $script:dataRoot = Join-Path $TestDrive 'data'
    function New-FakeRun {
        # Writes Runs\<id>\run.json and returns @{ Id; Directory; Record }.
        param([string]$Status, $ControllerPid = $null)
        $id = [guid]::NewGuid().ToString('N')
        $directory = Join-Path (Join-Path $script:dataRoot 'Runs') $id
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $record = [ordered]@{
            schemaVersion = 2
            id = $id
            name = 'StopRunFixture'
            status = $Status
            startedUtc = [DateTime]::UtcNow.ToString('o')
            finishedUtc = $null
            controllerPid = $ControllerPid
            controllerStartedUtc = [DateTime]::UtcNow.ToString('o')
            currentComponent = ''
            message = 'synthetic'
        }
        [IO.File]::WriteAllText((Join-Path $directory 'run.json'), ($record | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        return @{ Id = $id; Directory = $directory; Record = (Join-Path $directory 'run.json') }
    }
    function Stop-FakeRun {
        param([string]$RunId, [switch]$Force)
        InModuleScope PASeasyInstall -Parameters @{
            RunId = $RunId
            DataRoot = $script:dataRoot
            Force = [bool]$Force
        } {
            param($RunId, $DataRoot, $Force)
            Stop-PASDeployment -RunId $RunId -DataRoot $DataRoot -Force:$Force -Confirm:$false
        }
    }
}

Describe 'Stop-PASDeployment on a run that already stopped' {
    It 'marks a <Status> run Abandoned and writes a RunStopped event' -TestCases @(
        @{ Status = 'Failed' }, @{ Status = 'Unknown' }, @{ Status = 'Blocked' }
    ) {
        param($Status)
        $run = New-FakeRun -Status $Status
        $result = Stop-FakeRun -RunId $run.Id
        $result.RunId | Should -BeExactly $run.Id
        $result.Status | Should -BeExactly 'Abandoned'
        $result.PreviousStatus | Should -BeExactly $Status
        $result.ControllerStopped | Should -BeFalse
        @($result.Locks).Count | Should -Be 0
        $stored = Get-Content -LiteralPath $run.Record -Raw | ConvertFrom-Json
        $stored.status | Should -BeExactly 'Abandoned'
        $stored.message | Should -Match ('was ' + $Status)
        $stored.abandonedUtc | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $run.Directory 'events.jsonl') -Raw) | Should -Match 'RunStopped'
    }
    It 'cannot be resumed afterwards' {
        $run = New-FakeRun -Status 'Failed'
        $null = Stop-FakeRun -RunId $run.Id
        { InModuleScope PASeasyInstall -Parameters @{ RunId = $run.Id; DataRoot = $script:dataRoot } {
                param($RunId, $DataRoot)
                Resume-PASDeployment -RunId $RunId -DataRoot $DataRoot -Confirm:$false
            } } | Should -Throw '*Cannot resume a run whose status is Abandoned*'
    }
    It 'leaves a Succeeded run as it is' {
        $run = New-FakeRun -Status 'Succeeded'
        $before = [IO.File]::ReadAllText($run.Record)
        $result = Stop-FakeRun -RunId $run.Id
        $result.Status | Should -BeExactly 'Succeeded'
        [IO.File]::ReadAllText($run.Record) | Should -BeExactly $before
    }
    It 'lists the lock folder of an unfinished server when no credentials are given' {
        $run = New-FakeRun -Status 'Failed'
        $payload = Join-Path (Join-Path $run.Directory 'Payloads') 'pvwa01'
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $payload 'inventory.psd1'), "@{SchemaVersion=1;Targets=@{pvwa01=@{Protocol='WinRM';Runtime='WindowsPowerShell';ComputerName='192.0.2.21'}}}")
        New-Item -ItemType Directory -Path (Join-Path $run.Directory 'pvwa01') -Force | Out-Null
        '{"status":"Failed","steps":{}}' | Set-Content -LiteralPath (Join-Path (Join-Path $run.Directory 'pvwa01') 'state.json')
        Mock Invoke-PASRemoteLock -ModuleName PASeasyInstall { throw 'No server may be contacted without -CredentialMap' }
        $result = Stop-FakeRun -RunId $run.Id 6>$null
        @($result.Locks).Count | Should -Be 1
        $result.Locks[0].Target | Should -BeExactly 'pvwa01'
        $result.Locks[0].Computer | Should -BeExactly '192.0.2.21'
        $result.Locks[0].LockFolder | Should -BeExactly 'C:\ProgramData\PAExec\locks\pvwa01'
        $result.Locks[0].Released | Should -BeFalse
        Should -Invoke Invoke-PASRemoteLock -ModuleName PASeasyInstall -Times 0
    }
    It 'does not list a server whose workflow succeeded' {
        $run = New-FakeRun -Status 'Failed'
        $payload = Join-Path (Join-Path $run.Directory 'Payloads') 'pvwa01'
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $payload 'inventory.psd1'), "@{SchemaVersion=1;Targets=@{pvwa01=@{Protocol='WinRM';ComputerName='192.0.2.21'}}}")
        New-Item -ItemType Directory -Path (Join-Path $run.Directory 'pvwa01') -Force | Out-Null
        '{"status":"Succeeded","steps":{}}' | Set-Content -LiteralPath (Join-Path (Join-Path $run.Directory 'pvwa01') 'state.json')
        @((Stop-FakeRun -RunId $run.Id).Locks).Count | Should -Be 0
    }
}

Describe 'Stop-PASDeployment on a run with a live controller' {
    # Liveness is decided by Test-PASControllerAlive (PID and process start time must both match the
    # run record). The tests replace it, so no process is inspected or stopped.
    BeforeEach {
        $global:PAeasyStopFixture = @{ Alive = $true; Stopped = 0 }
        Mock Test-PASControllerAlive -ModuleName PASeasyInstall { return $global:PAeasyStopFixture.Alive }
        Mock Stop-Process -ModuleName PASeasyInstall {
            $global:PAeasyStopFixture.Stopped++
            $global:PAeasyStopFixture.Alive = $false
        }
        Mock Start-Sleep -ModuleName PASeasyInstall {}
    }
    AfterAll { Remove-Variable -Name PAeasyStopFixture -Scope Global -ErrorAction SilentlyContinue }

    It 'refuses without -Force and changes nothing' {
        $run = New-FakeRun -Status 'Running' -ControllerPid 4242
        $before = [IO.File]::ReadAllText($run.Record)
        { Stop-FakeRun -RunId $run.Id } | Should -Throw '*is still running*-Force*'
        [IO.File]::ReadAllText($run.Record) | Should -BeExactly $before
        Test-Path -LiteralPath (Join-Path $run.Directory 'events.jsonl') | Should -BeFalse
        $global:PAeasyStopFixture.Stopped | Should -Be 0
    }
    It 'stops the controller with -Force and marks the run Abandoned' {
        $run = New-FakeRun -Status 'Running' -ControllerPid 4242
        $result = Stop-FakeRun -RunId $run.Id -Force
        $global:PAeasyStopFixture.Stopped | Should -Be 1
        Should -Invoke Stop-Process -ModuleName PASeasyInstall -Times 1 -ParameterFilter { $Id -eq 4242 }
        $result.ControllerStopped | Should -BeTrue
        $result.PreviousStatus | Should -BeExactly 'Running'
        $result.Status | Should -BeExactly 'Abandoned'
        (Get-Content -LiteralPath $run.Record -Raw | ConvertFrom-Json).status | Should -BeExactly 'Abandoned'
    }
    It 'stops nothing when the process cannot be confirmed as this run''s controller' {
        # $null: the process list could not be read, so nobody may conclude anything.
        $global:PAeasyStopFixture.Alive = $null
        $run = New-FakeRun -Status 'Running' -ControllerPid 4242
        $before = [IO.File]::ReadAllText($run.Record)
        { Stop-FakeRun -RunId $run.Id -Force } | Should -Throw '*cannot be confirmed as the controller*'
        $global:PAeasyStopFixture.Stopped | Should -Be 0
        [IO.File]::ReadAllText($run.Record) | Should -BeExactly $before
    }
    It 'refuses a run that is starting and has no controller process yet' {
        $run = New-FakeRun -Status 'Launching'
        { Stop-FakeRun -RunId $run.Id -Force } | Should -Throw '*has no controller process yet*'
        $global:PAeasyStopFixture.Stopped | Should -Be 0
    }
    It 'treats a run whose controller is gone as Interrupted and abandons it without -Force' {
        $global:PAeasyStopFixture.Alive = $false
        $run = New-FakeRun -Status 'Running' -ControllerPid 4242
        $result = Stop-FakeRun -RunId $run.Id
        $result.PreviousStatus | Should -BeExactly 'Interrupted'
        $result.Status | Should -BeExactly 'Abandoned'
        $global:PAeasyStopFixture.Stopped | Should -Be 0
    }
}

Describe 'Stop-PASRun argument checks' {
    It 'rejects an id that is not a run id' {
        { Stop-PASRun -RunId 'not-an-id' -Confirm:$false } | Should -Throw
    }
    It 'reports a run that does not exist' {
        { InModuleScope PASeasyInstall -Parameters @{ DataRoot = $script:dataRoot } {
                param($DataRoot)
                Stop-PASDeployment -RunId ('f' * 32) -DataRoot $DataRoot -Confirm:$false
            } } | Should -Throw '*was not found*'
    }
}

Describe 'Find-PASLocalLockOwner (a blocked run names the run that holds the server)' {
    It 'finds an unfinished run of this controller on the same address, and forgets it once its locks were released' {
        $run = New-FakeRun -Status 'Abandoned'
        $payload = Join-Path (Join-Path $run.Directory 'Payloads') 'psmp01'
        New-Item -ItemType Directory -Path $payload -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $payload 'inventory.psd1'), "@{SchemaVersion=1;Targets=@{psmp01=@{Protocol='SSH';Runtime='Bash';ComputerName='192.0.2.31'}}}")
        New-Item -ItemType Directory -Path (Join-Path $run.Directory 'psmp01') -Force | Out-Null
        '{"status":"Unknown","steps":{}}' | Set-Content -LiteralPath (Join-Path (Join-Path $run.Directory 'psmp01') 'state.json')
        $find = {
            param($Address, $RunId)
            InModuleScope PASeasyInstall -Parameters @{ Address = $Address; RunId = $RunId; DataRoot = $script:dataRoot } {
                param($Address, $RunId, $DataRoot)
                Find-PASLocalLockOwner -Address $Address -RunId $RunId -DataRoot $DataRoot
            }
        }
        & $find '192.0.2.31' ([guid]::NewGuid().ToString('N')) | Should -BeExactly $run.Id
        & $find '192.0.2.99' ([guid]::NewGuid().ToString('N')) | Should -BeExactly ''
        # The run itself is never its own blocker.
        & $find '192.0.2.31' $run.Id | Should -BeExactly ''
        $record = Get-Content -Raw $run.Record | ConvertFrom-Json
        $record | Add-Member NoteProperty locksReleased $true -Force
        [IO.File]::WriteAllText($run.Record, ($record | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
        & $find '192.0.2.31' ([guid]::NewGuid().ToString('N')) | Should -BeExactly ''
    }
}
