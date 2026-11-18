BeforeAll {
    $modulePath=Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1'
    Import-Module $modulePath -Force
}
Describe 'Controller-wide resource coordination' {
    It 'blocks different DataRoots, preserves a killed controller claim, and permits only owning-run reconciliation' {
        Initialize-PASeasyController | Out-Null
        $name='qualification-'+[guid]::NewGuid().ToString('N')
        $first=Join-Path $TestDrive 'first';$second=Join-Path $TestDrive 'second'
        $ready=Join-Path $TestDrive 'ready';$childFile=Join-Path $TestDrive 'hold.ps1'
        @'
param($Module,$Name,$Root,$Ready)
$ErrorActionPreference='Stop'
Import-Module $Module -Force
& (Get-Module PASeasyInstall.Core) {param($n,$r,$f)
    $g=Enter-PASeasyGate -Name $n -DataRoot $r -RunId owner -TimeoutSeconds 1
    [IO.File]::WriteAllText($f,'held')
    Start-Sleep -Seconds 45
} $Name $Root $Ready
'@ | Set-Content $childFile
        $arguments=@('-NoProfile','-File',('"'+$childFile+'"'),('"'+$modulePath+'"'),$name,('"'+$first+'"'),('"'+$ready+'"'))
        $child=Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $TestDrive 'child-error.txt')
        $gate=$null
        try{
            $deadline=[DateTime]::UtcNow.AddSeconds(15)
            while(-not(Test-Path $ready) -and [DateTime]::UtcNow -lt $deadline -and -not $child.HasExited){Start-Sleep -Milliseconds 100}
            if(-not(Test-Path $ready)){throw ('Child did not acquire gate: '+(Get-Content (Join-Path $TestDrive 'child-error.txt') -Raw))}
            {& (Get-Module PASeasyInstall.Core) {param($n,$r) Enter-PASeasyGate -Name $n -DataRoot $r -RunId different -TimeoutSeconds 1} $name $second} | Should -Throw '*held by another process*'
            Stop-Process -Id $child.Id -Force;$child.WaitForExit()
            {& (Get-Module PASeasyInstall.Core) {param($n,$r) Enter-PASeasyGate -Name $n -DataRoot $r -RunId different -TimeoutSeconds 1} $name $second} | Should -Throw '*Unreconciled*'
            {& (Get-Module PASeasyInstall.Core) {param($n,$r) Enter-PASeasyGate -Name $n -DataRoot $r -RunId owner -TimeoutSeconds 1} $name $second} | Should -Throw '*Unreconciled*'
            $gate=& (Get-Module PASeasyInstall.Core) {param($n,$r) Enter-PASeasyGate -Name $n -DataRoot $r -RunId owner -TimeoutSeconds 1} $name $first
            $gate.Complete();$gate.Dispose();$gate=$null
            $gate=& (Get-Module PASeasyInstall.Core) {param($n,$r) Enter-PASeasyGate -Name $n -DataRoot $r -RunId different -TimeoutSeconds 1} $name $second
            $gate.Complete()
        }finally{
            if(-not $child.HasExited){Stop-Process -Id $child.Id -Force;$child.WaitForExit()}
            if($gate){$gate.Dispose()}
        }
    }
    It 'uses one canonical IP identity for alternate literal notation' {
        & (Get-Module PASeasyInstall.Core) {Get-PASeasyResourceIdentity '::ffff:10.0.0.1'} | Should -Be '10.0.0.1'
    }
    It 'rejects host-ID aliases that bypass dedicated Vault policy' {
        $c=New-PASeasyConfig -Template Vault -Path (Join-Path $TestDrive 'aliases.json') -WhatIf
        $c.hosts.other=@{address=$c.hosts.vault01.address;os='Windows'}
        $c.components+=@{id='pvwa';host='other';type='PVWA';variant='Standard';options=@{}}
        (Test-PASeasyConfig -Configuration $c).Issues -join ' ' | Should -Match 'same endpoint'
    }
}
