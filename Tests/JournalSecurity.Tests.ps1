BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
}
Describe 'Secret-bearing task outputs and remote evidence' {
    It 'filters target output before detached stdout or status can be persisted' {
        $marker = 'synthetic-' + [guid]::NewGuid().ToString('N')
        $code = 'param($VaultPassword) Write-Output ("vendor output "+$VaultPassword); [pscustomobject]@{Changed=$true;Message=$VaultPassword;Data=@{Metadata=$VaultPassword}}'
        $r = & (Join-Path $root 'PASeasyInstall/Private/Engine/Assets/TaskHost.ps1') -Code $code -Parameters @{VaultPassword = $marker }
        ($r | ConvertTo-Json -Depth 10) | Should -Not -Match $marker
        $r.Ok | Should -BeTrue
    }
    It 'rejects arbitrary target Data before it can enter detached status' {
        $code = '[pscustomobject]@{Changed=$false;Message="done";Data=@{UntrustedPayload="sensitive"}}'
        $r = & (Join-Path $root 'PASeasyInstall/Private/Engine/Assets/TaskHost.ps1') -Code $code -Parameters @{}
        $r.Ok | Should -BeFalse
        $r.Terminal.Data | Should -BeNullOrEmpty
    }
    It 'projects remote results without raw Data and redacts supplied secret values' {
        & (Get-Module PASeasyInstall) {
            $secret = 'synthetic-marker'
            $remote = @{state = 'Succeeded'; message = "error $secret"; data = @{arbitrary = $secret }; unexpected = $secret; exitCode = 0 }
            $safe = Select-PASRemoteEvidence $remote @($secret)
            ($safe | ConvertTo-Json) | Should -Not -Match $secret
            $safe.ContainsKey('data') | Should -BeFalse
            $safe.ContainsKey('unexpected') | Should -BeFalse
            { Select-PASSafeData @{Metadata = $secret } @($secret) } | Should -Throw '*Sensitive*'
        }
    }
}
