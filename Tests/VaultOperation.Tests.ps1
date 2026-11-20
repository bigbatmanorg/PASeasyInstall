BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Bounded authenticated-operation admission and release' {
    BeforeEach {
        $global:PAeasyVaultOperationFixture=@{Gates=(New-Object System.Collections.ArrayList);Preexisting=$false;Polls=0}
        Mock Get-PASResourceIdentity -ModuleName PASeasyInstall.Core {@('192.0.2.12','192.0.2.11','192.0.2.12')}
        Mock Enter-PASGate -ModuleName PASeasyInstall.Core {
            $g=[pscustomobject]@{Name=$Name;PreexistingClaim=$global:PAeasyVaultOperationFixture.Preexisting;Completed=$false;Disposed=$false}
            $g|Add-Member ScriptMethod Complete {$this.Completed=$true}
            $g|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
            [void]$global:PAeasyVaultOperationFixture.Gates.Add($g)
            return $g
        }
    }
    It 'admits every canonical identity in deterministic order and releases after confirmed completion' {
        & (Get-Module PASeasyInstall.Core) {
            $gates=@(Enter-PASVaultOperation -Address vault.test -DataRoot C:\operation-test -RunId run0001)
            @($gates.Name)|Should -Be @('vault-192.0.2.11','vault-192.0.2.12')
            Exit-PASVaultOperation -Gates $gates -Succeeded $true
            @($gates|Where-Object {-not $_.Completed -or -not $_.Disposed}).Count|Should -Be 0
        }
    }
    It 'retains durable claims while releasing mutexes after an uncertain authenticated attempt' {
        & (Get-Module PASeasyInstall.Core) {
            $gates=@(Enter-PASVaultOperation -Address vault.test -DataRoot C:\operation-test -RunId run0001)
            Exit-PASVaultOperation -Gates $gates -Succeeded $false
            @($gates|Where-Object {$_.Completed -or -not $_.Disposed}).Count|Should -Be 0
        }
    }
    It 'removes only new partial claims if another canonical address refuses admission before login' {
        Mock Enter-PASGate -ModuleName PASeasyInstall.Core {throw 'held by another process'} -ParameterFilter {$Name -eq 'vault-192.0.2.12'}
        {& (Get-Module PASeasyInstall.Core) {Enter-PASVaultOperation -Address vault.test -DataRoot C:\operation-test -RunId run0001}}|Should -Throw '*held by another process*'
        & (Get-Module PASeasyInstall.Core) {
            $global:PAeasyVaultOperationFixture.Gates.Count|Should -Be 1
            $global:PAeasyVaultOperationFixture.Gates[0].Completed|Should -BeTrue
            $global:PAeasyVaultOperationFixture.Gates[0].Disposed|Should -BeTrue
        }
    }
    It 'never removes a prior unresolved claim during partial admission cleanup' {
        & (Get-Module PASeasyInstall.Core) {$global:PAeasyVaultOperationFixture.Preexisting=$true}
        Mock Enter-PASGate -ModuleName PASeasyInstall.Core {throw 'held by another process'} -ParameterFilter {$Name -eq 'vault-192.0.2.12'}
        {& (Get-Module PASeasyInstall.Core) {Enter-PASVaultOperation -Address vault.test -DataRoot C:\operation-test -RunId run0001}}|Should -Throw
        & (Get-Module PASeasyInstall.Core) {
            $global:PAeasyVaultOperationFixture.Gates[0].Completed|Should -BeFalse
            $global:PAeasyVaultOperationFixture.Gates[0].Disposed|Should -BeTrue
        }
    }
    It 'does not release a successful registration claim until the same durable worker has exited' {
        Mock Get-PASDetachedStatus -ModuleName PASeasyInstall.Core {
            $global:PAeasyVaultOperationFixture.Polls++
            @{state='Succeeded';workerActive=($global:PAeasyVaultOperationFixture.Polls -lt 2)}
        }
        Mock Start-Sleep -ModuleName PASeasyInstall.Core {}
        & (Get-Module PASeasyInstall.Core) {
            $gates=@(Enter-PASVaultOperation -Address vault.test -DataRoot C:\operation-test -RunId run0001)
            Complete-PASVaultOperation $gates @{} @{} @{status='Succeeded';attemptId=('a'*32)} Detached
            $global:PAeasyVaultOperationFixture.Polls|Should -Be 2
            @($gates|Where-Object {-not $_.Completed -or -not $_.Disposed}).Count|Should -Be 0
        }
    }
    It 'rejects missing worker-exit evidence and never assumes an acknowledged process has exited' {
        Mock Get-PASDetachedStatus -ModuleName PASeasyInstall.Core {@{state='Succeeded'}}
        {& (Get-Module PASeasyInstall.Core) {Wait-PASDetachedSessionQuiescence @{} @{} ('a'*32) -TimeoutSeconds 0}}|Should -Throw '*exit is unconfirmed*'
        Mock Get-PASDetachedStatus -ModuleName PASeasyInstall.Core {@{state='Interrupted';workerActive=$false}}
        {& (Get-Module PASeasyInstall.Core) {Wait-PASDetachedSessionQuiescence @{} @{} ('a'*32) -TimeoutSeconds 0}}|Should -Throw '*successful terminal record*'
    }
}

AfterAll {Remove-Variable -Name PAeasyVaultOperationFixture -Scope Global -ErrorAction SilentlyContinue}
