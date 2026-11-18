$repo=Split-Path -Parent $PSScriptRoot
$modules=Join-Path $repo 'Modules'
BeforeAll {
    $repo=Split-Path -Parent $PSScriptRoot
    $modules=Join-Path $repo 'Modules'
    Import-Module (Join-Path $modules 'PASeasyInstall.Orchestrator/PASeasyInstall.Orchestrator.psd1') -Force
    # Engine-level journal reader used by one test below (the Orchestrator imports Core privately).
    Import-Module (Join-Path $modules 'PASeasyInstall.Core/PASeasyInstall.Core.psd1')
}
Describe 'UI-first independent modules' {
    It 'has a manifest per component and no native desktop imports in the deployment engine' {
        foreach($component in @('Core','Vault','DR','PVWA','CPM','PSM','PSMP','PTA','AD','Orchestrator','UI')){
            $manifest=Join-Path $modules ('PASeasyInstall.'+$component+'/PASeasyInstall.'+$component+'.psd1')
            (Test-Path -LiteralPath $manifest) | Should -BeTrue
        }
        (Get-Content (Join-Path $modules 'PASeasyInstall.Core/PASeasyInstall.Core.psm1') -Raw) | Should -Not -Match 'Import-Module NativeHTMLKit'
    }
    It 'creates a fresh Primary with no DR by default' {
        $config=New-PASFreshEnvironment -Environment LabVault -PrimaryIP '192.0.2.11' -ControllerIP '192.0.2.10' -MediaRoot 'C:\Media'
        @($config.components).Count | Should -Be 1
        $config.components[0].type | Should -Be 'Vault'
        $config.vault.existing | Should -BeFalse
        (Test-PASEnvironment -Configuration $config).Valid | Should -BeTrue
    }
    It 'supports DR only in a new Primary + DR pair' {
        $config=New-PASFreshEnvironment -Environment LabDR -PrimaryIP '192.0.2.11' -DRIP '192.0.2.12' -ControllerIP '192.0.2.10' -MediaRoot 'C:\Media' -WithDR
        @($config.components).Count | Should -Be 2
        @($config.components|Where-Object {$_.type -eq 'DRVault'}).Count | Should -Be 1
        (Test-PASEnvironment -Configuration $config).Valid | Should -BeTrue
        $config.vault.existing=$true
        { Test-PASEnvironment -Configuration $config } | Should -Throw '*DR*'
    }
    It 'rejects selecting DR without a fresh Primary' {
        {New-PASFreshEnvironment -PrimaryIP '192.0.2.11' -DRIP '192.0.2.12' -ControllerIP '192.0.2.10' -MediaRoot 'C:\Media'} | Should -Throw '*DR IP*'
    }
    It 'plans a component against an existing Vault without importing the GUI' {
        $plan=New-PASExistingVaultComponent -Component PSM -Environment NewPSM -VaultAddress '192.0.2.11' -TargetAddress '192.0.2.21' -MediaZip 'C:\Media\psm.zip'
        $plan.vault.existing | Should -BeTrue
        @($plan.components|Where-Object {$_.type -eq 'Vault'}).Count | Should -Be 0
        @((Get-PASEnvironmentPlan -Configuration $plan).Items).Count | Should -Be 1
    }
    It 'does not import NativeHTMLKit when importing the orchestrator' {
        @(Get-Module NativeHTMLKit.UI).Count | Should -Be 0
    }
    It 'normalizes JSONL events without guessing installation percent complete' {
        $id='a'*32
        $base=Join-Path $TestDrive 'data'
        $dir=Join-Path (Join-Path $base 'Runs') $id
        $folder=Join-Path $dir 'vault'
        $null=New-Item -Path $folder -ItemType Directory -Force
        [IO.File]::WriteAllText((Join-Path $folder 'events.jsonl'),(@'
{"schemaVersion":1,"timestampUtc":"2026-11-18T12:00:00Z","sequence":1,"target":"vault","taskId":"install-server","type":"TaskStarted","level":"Information","message":"started"}
{"schemaVersion":1,"timestampUtc":"2026-11-18T12:00:05Z","sequence":2,"target":"vault","taskId":"install-server","type":"TaskCompleted","level":"Information","message":"finished"}
'@),[Text.UTF8Encoding]::new($false))
        $events=@(Get-PASDeploymentEvents -RunId $id -DataRoot $base)
        $events.Count | Should -Be 2
        $events[0].Stage | Should -Be 'install-server'
        $events[1].Status | Should -Be 'Complete'
    }
    It 'escapes untrusted JSONL message text in dashboard cards' {
        . (Join-Path $modules 'PASeasyInstall.UI/Presentation.ps1')
        $snapshot=[pscustomobject]@{RunId=('b'*32);Status='Running';CurrentComponent='vault';LastStep='install';ErrorEvents=0;
          Events=@([pscustomobject]@{TimestampUtc='2026-11-18T12:00:00Z';Status='Running';Component='vault';Stage='install';Event='TaskStarted';Message='<script>alert(1)</script>'})}
        $html=ConvertTo-PASUIDashboardHtml $snapshot
        $html | Should -Not -Match '<script>'
        $html | Should -Match '&lt;script&gt;'
    }
}
