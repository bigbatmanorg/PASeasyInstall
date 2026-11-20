BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
    $bootstrap=Join-Path $root 'PASeasyInstall/Controllers/Invoke-V2Controller.ps1'
    function New-LeaseFixture {
        param([string]$Base)
        $id=[guid]::NewGuid().ToString('N');$dir=Join-Path (Join-Path $Base 'Runs') $id
        New-Item $dir -ItemType Directory -Force|Out-Null
        $path=Join-Path $dir 'run-v2.json'
        @{schemaVersion=2;id=$id;name='SyntheticLeaseFixture';status='Running';controllerPid=$PID;controllerStartedUtc=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o');finishedUtc=$null;message='Owner fixture'}|ConvertTo-Json|Set-Content $path
        [IO.File]::WriteAllText((Join-Path $dir 'events-v2.jsonl'),'synthetic owner event')
        [pscustomobject]@{Id=$id;Directory=$dir;Path=$path;Root=$Base}
    }
}
Describe 'Controller lifetime admission before metadata (no remote targets)' {
    It 'keeps owner metadata/events byte-identical when a second real bootstrap loses admission' {
        $f=New-LeaseFixture (Join-Path $TestDrive 'bootstrap-contender')
        $before=(Get-FileHash $f.Path).Hash;$eventPath=Join-Path $f.Directory 'events-v2.jsonl';$events=(Get-FileHash $eventPath).Hash
        $lease=[IO.File]::Open((Join-Path $f.Directory 'controller.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $envelope=Join-Path $f.Directory 'credentials-contender.json';[IO.File]::WriteAllText($envelope,'SYNTHETIC_UNUSED_ENVELOPE')
        $child=$null
        try{
            $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $PSHOME 'powershell.exe'
            $start.Arguments='-NoProfile -NonInteractive -File "'+$bootstrap+'" -RunId '+$f.Id+' -DataRoot "'+$f.Root+'" -Envelope "'+$envelope+'" -Resume'
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardError=$true
            $child=[Diagnostics.Process]::new();$child.StartInfo=$start;[void]$child.Start();$errors=$child.StandardError.ReadToEndAsync()
            $child.WaitForExit(15000)|Should -BeTrue;$child.ExitCode|Should -Be 1
            (Get-FileHash $f.Path).Hash|Should -BeExactly $before
            (Get-FileHash $eventPath).Hash|Should -BeExactly $events
            Test-Path $envelope|Should -BeFalse
            $errors.GetAwaiter().GetResult()|Should -Not -Match SYNTHETIC_UNUSED_ENVELOPE
            Test-Path (Join-Path $f.Directory 'config.json')|Should -BeFalse
        }finally{if($child){if(-not $child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()};$lease.Dispose()}
        Test-Path (Join-Path $f.Directory 'controller.lock')|Should -BeTrue
    }
    It 'rejects a foreground contender without entering Core or changing the owner' {
        $f=New-LeaseFixture (Join-Path $TestDrive 'foreground-contender');$before=(Get-FileHash $f.Path).Hash
        $lease=[IO.File]::Open((Join-Path $f.Directory 'controller.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        Mock Invoke-PASRunControllerCore -ModuleName PASeasyInstall.Core {throw 'Core must not execute'}
        try{
            {& (Get-Module PASeasyInstall.Core) {param($id,$base) Invoke-PASRunController -RunId $id -DataRoot $base -Resume -InMemoryAuth @{Credentials=@{};Secrets=@{}}} $f.Id $f.Root}|Should -Throw '*PAExecLocked*'
            (Get-FileHash $f.Path).Hash|Should -BeExactly $before
            Should -Invoke Invoke-PASRunControllerCore -ModuleName PASeasyInstall.Core -Times 0
        }finally{$lease.Dispose()}
    }
    It 'releases the lifetime lock after owned early initialization failure and retains the lockfile' {
        $f=New-LeaseFixture (Join-Path $TestDrive 'early-failure')
        Mock Invoke-PASRunControllerCore -ModuleName PASeasyInstall.Core {throw 'SYNTHETIC_PRIVATE_INITIALIZATION_DETAIL'}
        {& (Get-Module PASeasyInstall.Core) {param($id,$base) Invoke-PASRunController -RunId $id -DataRoot $base -Resume -InMemoryAuth @{Credentials=@{};Secrets=@{}}} $f.Id $f.Root}|Should -Throw '*SYNTHETIC_PRIVATE*'
        $run=Get-Content $f.Path -Raw|ConvertFrom-Json
        $run.status|Should -BeExactly LaunchFailed
        [IO.File]::ReadAllText($f.Path)|Should -Not -Match SYNTHETIC_PRIVATE_INITIALIZATION_DETAIL
        $lease=[IO.File]::Open((Join-Path $f.Directory 'controller.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $lease.Dispose();Test-Path (Join-Path $f.Directory 'controller.lock')|Should -BeTrue
    }
    It 'releases an actual owned controller lease on process termination and admits explicit resume' {
        $f=New-LeaseFixture (Join-Path $TestDrive 'terminated-owner')
        $driver=Join-Path $TestDrive 'lease-owner.ps1';$ready=Join-Path $TestDrive 'owner-ready.txt'
        [IO.File]::WriteAllText($driver,@'
param($Module,$RunId,$DataRoot,$Ready)
Import-Module $Module -Force
& (Get-Module PASeasyInstall.Core) {
 param($id,$base,$readyPath)
 $script:LeaseFixtureReady=$readyPath
 function script:Invoke-PASRunControllerCore {
  param($RunId,$DataRoot,$Envelope,[switch]$Resume,$InMemoryAuth)
  $path=Join-Path (Get-PASRunDirectory $RunId $DataRoot) 'run-v2.json'
  $run=Read-PASJson $path;$run.status='Running';Write-PASJsonAtomic $path $run
  [IO.File]::WriteAllText($script:LeaseFixtureReady,'Synthetic controller owns lease; NO remote targets')
  Start-Sleep -Seconds 60
 }
 Invoke-PASRunController -RunId $id -DataRoot $base -Resume -InMemoryAuth @{Credentials=@{};Secrets=@{}}
} $RunId $DataRoot $Ready
'@)
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $PSHOME 'powershell.exe'
        $start.Arguments='-NoProfile -NonInteractive -File "'+$driver+'" -Module "'+(Join-Path $root 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1')+'" -RunId '+$f.Id+' -DataRoot "'+$f.Root+'" -Ready "'+$ready+'"'
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true
        $child=[Diagnostics.Process]::new();$child.StartInfo=$start;[void]$child.Start()
        try{
            $deadline=[DateTime]::UtcNow.AddSeconds(15)
            while(-not(Test-Path $ready) -and [DateTime]::UtcNow -lt $deadline -and -not $child.HasExited){Start-Sleep -Milliseconds 100}
            Test-Path $ready|Should -BeTrue
            (Get-Content $f.Path -Raw|ConvertFrom-Json).controllerPid|Should -Be $child.Id
            {[IO.File]::Open((Join-Path $f.Directory 'controller.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}|Should -Throw
            $child.Kill();$child.WaitForExit(5000)|Should -BeTrue
            (Get-PASRunRecord -RunId $f.Id -DataRoot $f.Root).status|Should -BeExactly Interrupted
            Mock Invoke-PASRunControllerCore -ModuleName PASeasyInstall.Core {
                $path=Join-Path (Join-Path (Join-Path $DataRoot 'Runs') $RunId) 'run-v2.json'
                $run=Get-Content $path -Raw|ConvertFrom-Json;$run.status='Succeeded'
                $run|ConvertTo-Json -Depth 10|Set-Content $path
            }
            & (Get-Module PASeasyInstall.Core) {param($id,$base) Invoke-PASRunController -RunId $id -DataRoot $base -Resume -InMemoryAuth @{Credentials=@{};Secrets=@{}}} $f.Id $f.Root
            (Get-Content $f.Path -Raw|ConvertFrom-Json).status|Should -BeExactly Succeeded
            Test-Path (Join-Path $f.Directory 'controller.lock')|Should -BeTrue
        }finally{if(-not $child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()}
    }
    It 'waits for a resumed child identity before treating an old terminal record as the new result' {
        $global:PAeasyLeasePoll=0;$stamp=[DateTime]::UtcNow
        Mock Get-PASRunRecord -ModuleName PASeasyInstall.Core {
            $global:PAeasyLeasePoll++
            if($global:PAeasyLeasePoll -eq 1){return [pscustomobject]@{status='Interrupted';controllerPid=90;controllerStartedUtc='2000-01-01T00:00:00Z';message='old result'}}
            [pscustomobject]@{status='Succeeded';controllerPid=91;controllerStartedUtc=[DateTime]::UtcNow.ToString('o');message='new result'}
        }
        Mock Start-Sleep -ModuleName PASeasyInstall.Core {}
        & (Get-Module PASeasyInstall.Core) {param($after) Wait-PASControllerCompletion -RunId ('a'*32) -DataRoot 'unused' -ControllerPid 91 -ControllerStartedAfterUtc $after} $stamp
        $global:PAeasyLeasePoll|Should -Be 2
        Remove-Variable PAeasyLeasePoll -Scope Global
    }
}
