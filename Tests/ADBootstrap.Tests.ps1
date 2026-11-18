BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.AD/Recipes/ActiveDirectory/AD-Task.ps1') -Settings @{Domain='paeasy.test'}
    $bootstrap=[scriptblock]::Create((Get-PASeasyADPromotionRebootScript))
}
Describe 'AD promotion reboot bootstrap authority' {
    BeforeEach {
        $id=[guid]::NewGuid().ToString('N');$dir=Join-Path $TestDrive $id;New-Item $dir -ItemType Directory | Out-Null
        $boot=([datetime]'2026-11-16T12:00:00Z').ToUniversalTime().ToString('o')
        $status=Join-Path $dir 'status.json';$marker=Join-Path $dir 'promotion.json';$checkpoint=Join-Path $dir 'checkpoint.json'
        @{schemaVersion=2;state='Succeeded';attemptId=$id;bootUtc=$boot;endedUtc=[DateTime]::UtcNow.AddMinutes(-1).ToString('o')} | ConvertTo-Json | Set-Content $status
        @{schemaVersion=2;attemptId=$id;bootUtc=$boot;domain='paeasy.test'} | ConvertTo-Json | Set-Content $marker
        @{schemaVersion=1;attemptId=$id;taskName=('PAeasy-AD-Promotion-Reboot-'+$id);bootUtc=$boot;domain='paeasy.test';statusPath=$status;promotionMarker=$marker;waitSeconds=1;graceSeconds=0} | ConvertTo-Json | Set-Content $checkpoint
        Mock Get-CimInstance { [pscustomobject]@{LastBootUpTime=[datetime]'2026-11-16T12:00:00Z'} }
        Mock Unregister-ScheduledTask {}
        Mock shutdown.exe { $global:LASTEXITCODE=0 }
    }
    It 'requests a reboot only after matching success, promotion and boot evidence' {
        & $bootstrap -Checkpoint $checkpoint
        Should -Invoke shutdown.exe -Exactly 1
        Test-Path (Join-Path $dir 'reboot-requested') | Should -BeTrue
    }
    It 'never requests the same reboot twice' {
        & $bootstrap -Checkpoint $checkpoint
        & $bootstrap -Checkpoint $checkpoint
        Should -Invoke shutdown.exe -Exactly 1
    }
    It 'cleans itself without another reboot when the boot already changed' {
        Mock Get-CimInstance { [pscustomobject]@{LastBootUpTime=[datetime]'2026-11-16T13:00:00Z'} }
        & $bootstrap -Checkpoint $checkpoint
        Should -Invoke shutdown.exe -Exactly 0
        Should -Invoke Unregister-ScheduledTask -Exactly 1
    }
    It 'never reboots after a failed promotion attempt' {
        $s=Get-Content $status -Raw | ConvertFrom-Json;$s.state='Failed';$s|ConvertTo-Json|Set-Content $status
        & $bootstrap -Checkpoint $checkpoint
        Should -Invoke shutdown.exe -Exactly 0
        Should -Invoke Unregister-ScheduledTask -Exactly 1
    }
    It 'rejects terminal evidence from another attempt' {
        $s=Get-Content $status -Raw | ConvertFrom-Json;$s.attemptId=[guid]::NewGuid().ToString('N');$s|ConvertTo-Json|Set-Content $status
        {& $bootstrap -Checkpoint $checkpoint} | Should -Throw '*immutable attempt*'
        Should -Invoke shutdown.exe -Exactly 0
    }
    It 'rejects a promotion marker for another domain' {
        $m=Get-Content $marker -Raw | ConvertFrom-Json;$m.domain='other.test';$m|ConvertTo-Json|Set-Content $marker
        {& $bootstrap -Checkpoint $checkpoint} | Should -Throw '*promotion marker*'
        Should -Invoke shutdown.exe -Exactly 0
    }
}

Describe 'AD promotion refuses actual Vault and DR products' {
    It 'permits a fresh target without Vault software' {
        Mock Get-Service {}
        {Assert-PASeasyADPromotionTarget} | Should -Not -Throw
    }
    It 'refuses existing Primary Vault software before AD mutation' {
        Mock Get-Service {[pscustomobject]@{Name='PrivateArk Server'}}
        {Assert-PASeasyADPromotionTarget} | Should -Throw '*Vault and DR hosts cannot be promoted*'
    }
    It 'refuses existing Disaster Recovery software before AD mutation' {
        Mock Get-Service {[pscustomobject]@{Name='CyberArk Vault Disaster Recovery'}}
        {Assert-PASeasyADPromotionTarget} | Should -Throw '*Vault and DR hosts cannot be promoted*'
    }
}
