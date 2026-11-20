BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Controller bootstrap failure and process identity' {
    It 'starts the private controller from the public detached API and rejects missing credentials before remote dispatch' {
        $dataRoot=Join-Path $TestDrive 'private-controller'
        $config=New-PASConfigurationTemplate -Template DomainJoin -Path (Join-Path $TestDrive 'private-controller.json') -WhatIf
        $config.name='BootstrapFixture'+[guid]::NewGuid().ToString('N')
        $id=$null
        try{
            $id=Start-PASDeployment -Configuration $config -DataRoot $dataRoot -Confirm:$false
            $deadline=[DateTime]::UtcNow.AddSeconds(20)
            do{
                $run=Get-PASRunRecord -RunId $id -DataRoot $dataRoot
                if($run.status -notin @('Launching','Running')){break}
                Start-Sleep -Milliseconds 100
            }while([DateTime]::UtcNow -lt $deadline)
            $run.status|Should -BeExactly Failed
            $run.message|Should -Match 'Missing host PSCredential'
            @(Get-ChildItem (Join-Path (Join-Path $dataRoot 'Runs') $id) -Filter 'credentials-*.json').Count|Should -Be 0
            @(Get-ChildItem (Join-Path (Join-Path $dataRoot 'Runs') $id) -Recurse -Filter state.json).Count|Should -Be 0
        }finally{
            if($id){
                # This isolated fixture failed before invoking any target engine;
                # reconcile only its unique environment and documentation-address host.
                & (Get-Module PASeasyInstall.Core) {
                    param($root,$runId,$name)
                    foreach($resource in @(('environment-'+$name),'host-192.0.2.13')){
                        $gate=Enter-PASGate -Name $resource -DataRoot $root -RunId $runId -TimeoutSeconds 1
                        try{$gate.Complete()}finally{$gate.Dispose()}
                    }
                } $dataRoot $id $config.name
            }
        }
    }
    It 'records a terminal bootstrap failure and removes its envelope before any target dispatch' {
        $runId=[guid]::NewGuid().ToString('N');$dataRoot=Join-Path $TestDrive 'bootstrap'
        $dir=Join-Path (Join-Path $dataRoot 'Runs') $runId;New-Item $dir -ItemType Directory -Force | Out-Null
        @{schemaVersion=2;id=$runId;status='Launching';controllerPid=$null;message='launching';finishedUtc=$null} | ConvertTo-Json | Set-Content (Join-Path $dir 'run-v2.json')
        # Invalid frozen metadata intentionally fails before credential loading or gates.
        '{}' | Set-Content (Join-Path $dir 'plan-v2.json')
        '{}' | Set-Content (Join-Path $dir 'config.json')
        $envelope=Join-Path $dir 'credentials-test.json';'SYNTHETIC_ENVELOPE_MARKER' | Set-Content $envelope
        $errorLog=Join-Path $TestDrive 'bootstrap-error.txt'
        $scriptPath=Join-Path $root 'PASeasyInstall/Controllers/Invoke-V2Controller.ps1'
        $args=@('-NoProfile','-File',('"'+$scriptPath+'"'),'-RunId',$runId,'-DataRoot',('"'+$dataRoot+'"'),'-Envelope',('"'+$envelope+'"'))
        $child=Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardError $errorLog
        try{
            $child.WaitForExit(15000) | Should -BeTrue
            $child.HasExited | Should -BeTrue
            $run=Get-PASRunRecord -RunId $runId -DataRoot $dataRoot
            $run.status | Should -Be 'LaunchFailed'
            $run.controllerPid | Should -Be $child.Id
            Test-Path $envelope | Should -BeFalse
            Get-Content $errorLog -Raw | Should -Not -Match 'SYNTHETIC_ENVELOPE_MARKER'
        }finally{if(-not $child.HasExited){Stop-Process $child.Id -Force}}
    }
    It 'recognizes a live foreground controller by PID and creation time without requiring RunId on argv' {
        $id=[guid]::NewGuid().ToString('N');$dataRoot=Join-Path $TestDrive 'foreground'
        $dir=Join-Path (Join-Path $dataRoot 'Runs') $id;New-Item $dir -ItemType Directory -Force | Out-Null
        @{id=$id;status='Running';controllerPid=$PID;controllerStartedUtc=[Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().ToString('o');message='running'} | ConvertTo-Json | Set-Content (Join-Path $dir 'run-v2.json')
        (Get-PASRunRecord -RunId $id -DataRoot $dataRoot).status | Should -Be 'Running'
    }
}
