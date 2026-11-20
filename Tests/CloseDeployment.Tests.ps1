# Close-PASDeployment: an unresolved run that blocks its environment can be closed by the operator, without
# touching servers, and only its own controller claims are released.
BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $env:PAS_EASY_DATA_ROOT = Join-Path $TestDrive 'data'
    Import-Module (Join-Path $repo 'Modules/PASeasyInstall.Orchestrator/PASeasyInstall.Orchestrator.psd1') -Force
    $script:core = Get-Module -All PASeasyInstall.Core | Select-Object -First 1
}

Describe 'Close-PASDeployment' {
    It 'abandons an Unknown run, releases only its claims and unblocks the environment' -Skip:($env:OS -ne 'Windows_NT') {
        $id = [guid]::NewGuid().ToString('N'); $other = [guid]::NewGuid().ToString('N')
        $runDir = Join-Path $env:PAS_EASY_DATA_ROOT "Runs\$id"
        New-Item -ItemType Directory -Force $runDir | Out-Null
        & $script:core { param($p, $d) Write-PASJsonAtomic -Path $p -Data $d } (Join-Path $runDir 'run-v2.json') ([ordered]@{
            schemaVersion = 2; id = $id; name = 'CloseTest'; status = 'Unknown'; startedUtc = [DateTime]::UtcNow.ToString('o'); controllerPid = $null; message = 'synthetic' })
        $root = & $script:core { Get-PASCoordinationRoot }
        if (-not (Test-Path $root)) { $null = & $script:core { Initialize-PASController } }
        $mine = Join-Path $root ('test-' + $id + '.json'); $theirs = Join-Path $root ('test-' + $other + '.json')
        try {
            Set-Content $mine (@{ RunId = $id; StateRoot = 'x' } | ConvertTo-Json -Compress)
            Set-Content $theirs (@{ RunId = $other; StateRoot = 'x' } | ConvertTo-Json -Compress)
            { & $script:core { Test-PASActiveEnvironment -Name 'CloseTest' -DataRoot $env:PAS_EASY_DATA_ROOT } } | Should -Throw '*unresolved deployment*'

            $r = Close-PASDeployment -RunId $id -Reason 'test servers reset' -Force
            $r.AbandonedRuns | Should -Be @($id)
            $r.ReleasedClaims | Should -Be 1
            Test-Path $mine | Should -BeFalse
            Test-Path $theirs | Should -BeTrue
            (Get-Content (Join-Path $runDir 'run-v2.json') -Raw | ConvertFrom-Json).status | Should -Be 'Abandoned'
            (Get-Content (Join-Path $runDir 'events-v2.jsonl') -Raw) | Should -Match 'RunAbandoned'
            { & $script:core { Test-PASActiveEnvironment -Name 'CloseTest' -DataRoot $env:PAS_EASY_DATA_ROOT } } | Should -Not -Throw
        } finally { Remove-Item $mine, $theirs -Force -ErrorAction SilentlyContinue }
    }

    It 'rejects an id that is not a deployment id' {
        { Close-PASDeployment -RunId 'not-an-id' -Reason 'x' -Force } | Should -Throw
    }
}
