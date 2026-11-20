BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
    $runner=Join-Path $root 'Modules/PASeasyInstall.Core/Private/Engine/Assets/WindowsDetachedRunner.ps1'
    $ownership=Join-Path $root 'Modules/PASeasyInstall.Core/Recipes/WindowsComponent/Ownership.ps1'
    function New-PublicationFixture {
        param([string]$Base,[string]$Boot,[switch]$OmitBoot)
        $dir=Join-Path $Base ([guid]::NewGuid().ToString('N'));New-Item $dir -ItemType Directory|Out-Null
        Copy-Item $ownership (Join-Path $dir 'ownership.ps1')
        Copy-Item $runner (Join-Path $dir 'runner.ps1')
        $status=@{schemaVersion=2;state='Dispatched';attemptId=(Split-Path $dir -Leaf)}
        if(-not $OmitBoot){$status.stagedBootUtc=$Boot}
        $status|ConvertTo-Json -Compress|Set-Content (Join-Path $dir 'status.json')
        @{schemaVersion=1;sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;requireAdministrator=$false}|ConvertTo-Json -Compress|Set-Content (Join-Path $dir 'principal.json')
        [IO.File]::WriteAllText((Join-Path $dir 'host.ps1'),@'
param($Directory,[switch]$DeleteInputs,[switch]$RequireProtectedInputs)
if(-not $RequireProtectedInputs){throw 'Protected-input contract absent'}
[IO.File]::WriteAllText((Join-Path $Directory 'synthetic-body-launched'),'one')
@{Ok=$true;Output='';ExitCode=0;Terminal=@{Message='Synthetic runner fixture';Changed=$false;Data=@{}}}
'@)
        return $dir
    }
    function Invoke-PublicationFixture {
        param([string]$Directory)
        $hashes=@{};foreach($name in @('runner.ps1','ownership.ps1','host.ps1')){$hashes[$name]=(Get-FileHash (Join-Path $Directory $name)).Hash}
        if(Test-Path (Join-Path $Directory 'recovery.ps1')){$hashes['recovery.ps1']=(Get-FileHash (Join-Path $Directory 'recovery.ps1')).Hash}
        $arguments=& (Get-Module PASeasyInstall.Core) {param($d,$h) New-PASDetachedLaunchArguments $d $h} $Directory $hashes
        $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $PSHOME 'powershell.exe';$start.Arguments=$arguments
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardError=$true
        $child=[Diagnostics.Process]::new();$child.StartInfo=$start
        [void]$child.Start();$errorTask=$child.StandardError.ReadToEndAsync()
        try{if(-not $child.WaitForExit(15000)){throw 'Synthetic runner did not exit'};[void]$errorTask.GetAwaiter().GetResult();return $child.ExitCode}
        finally{if(-not $child.HasExited){Stop-Process $child.Id -Force};$child.Dispose()}
    }
}
Describe 'Actual Windows runner staged-boot admission (synthetic bodies only)' {
    It 'rechecks a recovery script after the body instead of executing changed bytes' {
        $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        $dir=New-PublicationFixture $TestDrive $boot
        [IO.File]::WriteAllText((Join-Path $dir 'recovery.ps1'),"[IO.File]::WriteAllText((Join-Path `$PSScriptRoot 'synthetic-recovery-launched'),'one')")
        $hostPath=Join-Path $dir 'host.ps1'
        $hostText=[IO.File]::ReadAllText($hostPath)
        $hostText=$hostText.Replace('@{Ok=',"Add-Content (Join-Path `$Directory 'recovery.ps1') '# synthetic changed bytes'`r`n@{Ok=")
        [IO.File]::WriteAllText($hostPath,$hostText)
        (Invoke-PublicationFixture $dir)|Should -Be 1
        Test-Path (Join-Path $dir 'synthetic-body-launched')|Should -BeTrue
        Test-Path (Join-Path $dir 'synthetic-recovery-launched')|Should -BeFalse
        $status=Get-Content (Join-Path $dir 'status.json') -Raw|ConvertFrom-Json
        $status.state|Should -BeExactly Failed;$status.recovery|Should -BeExactly Failed
        $status.message|Should -Match 'executable hash changed'
    }
    It 'pins executable dependencies before a fresh process can execute the runner' {
        $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        foreach($corrupt in @($false,$true)){
            $dir=New-PublicationFixture $TestDrive $boot
            $hashes=@{};foreach($name in @('runner.ps1','ownership.ps1','host.ps1')){$hashes[$name]=(Get-FileHash (Join-Path $dir $name)).Hash}
            $arguments=& (Get-Module PASeasyInstall.Core) {param($d,$h) New-PASDetachedLaunchArguments $d $h} $dir $hashes
            $arguments|Should -Match ([regex]::Escape((Split-Path $dir -Leaf)))
            if($corrupt){[IO.File]::WriteAllText((Join-Path $dir 'host.ps1'),'throw "Synthetic corrupted dependency must not execute"')}
            $errorLog=Join-Path $dir 'launch-error.txt'
            $start=[Diagnostics.ProcessStartInfo]::new()
            $start.FileName=Join-Path $PSHOME 'powershell.exe';$start.Arguments=$arguments
            $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardError=$true
            $child=[Diagnostics.Process]::new();$child.StartInfo=$start
            [void]$child.Start();$errorTask=$child.StandardError.ReadToEndAsync()
            try{
                $child.WaitForExit(15000)|Should -BeTrue
                [IO.File]::WriteAllText($errorLog,$errorTask.GetAwaiter().GetResult())
                if($corrupt){
                    $child.ExitCode|Should -Be 1
                    Test-Path (Join-Path $dir 'synthetic-body-launched')|Should -BeFalse
                    Test-Path (Join-Path $dir 'claimed')|Should -BeFalse
                    [IO.File]::ReadAllText($errorLog)|Should -Match 'executable hash changed'
                }else{
                    $child.ExitCode|Should -Be 0
                    Test-Path (Join-Path $dir 'synthetic-body-launched')|Should -BeTrue
                }
            }finally{if(-not $child.HasExited){Stop-Process $child.Id -Force};$child.Dispose()}
        }
    }
    It 'refuses a staged attempt from an older boot before any task body runs' {
        $dir=New-PublicationFixture $TestDrive '2000-01-01T00:00:00.0000000Z'
        (Invoke-PublicationFixture $dir)|Should -Be 4
        Test-Path (Join-Path $dir 'synthetic-body-launched')|Should -BeFalse
        (Get-Content (Join-Path $dir 'status.json') -Raw|ConvertFrom-Json).state|Should -BeExactly Dispatched
    }
    It 'refuses a missing staged-boot identity before any task body runs' {
        $dir=New-PublicationFixture $TestDrive -OmitBoot
        (Invoke-PublicationFixture $dir)|Should -Be 4
        Test-Path (Join-Path $dir 'synthetic-body-launched')|Should -BeFalse
    }
    It 'allows a current-boot fixture exactly once and flushes a terminal record' {
        $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        $dir=New-PublicationFixture $TestDrive $boot
        (Invoke-PublicationFixture $dir)|Should -Be 0
        Test-Path (Join-Path $dir 'synthetic-body-launched')|Should -BeTrue
        $status=Get-Content (Join-Path $dir 'status.json') -Raw|ConvertFrom-Json
        $status.state|Should -BeExactly Succeeded;$status.bootUtc|Should -BeExactly $boot
        (Invoke-PublicationFixture $dir)|Should -Be 3
        [IO.File]::ReadAllText((Join-Path $dir 'synthetic-body-launched'))|Should -BeExactly one
    }
}
