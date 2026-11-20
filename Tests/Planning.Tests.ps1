BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1'); Import-PASTestModule; . (Get-PASTestPrivateProxy)
}
Describe 'Multi-component execution inventory' {
    It 'builds an accepted <Type> inventory with AD disabled and no optional domain, preserving the input' -TestCases @(@{Type='PVWA';OS='Windows'},@{Type='PSMP';OS='Linux'}) {
        param($Type,$OS)
        $c=New-PASConfigurationTemplate -Template ExistingVault -Path (Join-Path $TestDrive ('optional-ad-'+$Type+'.json')) -WhatIf
        $c.activeDirectory=@{mode='None';join=@()}
        $c.hosts=@{plain=@{address='192.0.2.31';os=$OS;user=$(if($OS -eq 'Linux'){'root'}else{'Administrator'})}}
        # The PSMP installer needs the operator's explicit EULA acceptance; validation refuses a PSMP without it.
        $options=@{}; if($Type -eq 'PSMP'){$options.acceptEula=$true}
        $c.components=@(@{id='component';type=$Type;host='plain';variant='Standard';options=$options})
        (Test-PASConfiguration -Configuration $c).Valid | Should -BeTrue
        $before=(Get-PASDeploymentPlan -Configuration $c).ConfigDigest
        $inventory=& (Get-Module PASeasyInstall) {param($value) New-PASRuntimeInventory -Config $value -RunDirectory 'unused' -SkipMediaHash} $c
        $inventory.Values.Components.component.Domain | Should -BeExactly ''
        $c.activeDirectory.Contains('domain') | Should -BeFalse
        (Get-PASDeploymentPlan -Configuration $c).ConfigDigest | Should -BeExactly $before
    }
    It 'preserves configuration while resolving every component' {
        $c=New-PASConfigurationTemplate -Template FullLab -Path (Join-Path $TestDrive 'full.json') -WhatIf
        $inventory=& (Get-Module PASeasyInstall) {param($value) New-PASRuntimeInventory -Config $value -RunDirectory 'unused'} $c
        $inventory.Values.Components.Count | Should -Be $c.components.Count
        foreach($component in $c.components){
            $inventory.Values.Components[$component.id].Type | Should -Be $component.type
            $inventory.Values.Components[$component.id].VaultAddress | Should -Be $c.vault.address
        }
        $c.security.profile | Should -Be 'Secure'
    }
    It 'retains TLS in Lab unless explicitly waived' {
        $c=New-PASConfigurationTemplate -Template ExistingVault -Path (Join-Path $TestDrive 'tls.json') -WhatIf
        $c.security.profile='Lab'
        $inventory=& (Get-Module PASeasyInstall) {param($value) New-PASRuntimeInventory -Config $value -RunDirectory 'unused'} $c
        $inventory.Targets.pvwa.UseSSL | Should -BeTrue
        $c.security.overrides=@{'WinRM.RequireHTTPS'=$false}
        $inventory=& (Get-Module PASeasyInstall) {param($value) New-PASRuntimeInventory -Config $value -RunDirectory 'unused'} $c
        $inventory.Targets.pvwa.UseSSL | Should -BeFalse
    }
    It 'places PSM reboot boundaries after vendor stages and includes PostInstall' {
        $c=New-PASConfigurationTemplate -Template FullLab -Path (Join-Path $TestDrive 'psm.json') -WhatIf
        $part=@($c.components | Where-Object type -eq PSM)[0];$part.media='unused.zip'
        $path=& (Get-Module PASeasyInstall) {param($part,$value,$dir) New-PASComponentWorkflow -Component $part -Configuration $value -RunDirectory $dir} $part $c $TestDrive
        $wf=Import-PowerShellDataFile $path
        $ids=@($wf.Steps | ForEach-Object {$_.Id})
        $ids | Should -Contain 'postinstall'
        foreach($stage in @('prerequisites','install','harden')){
            $idx=[array]::IndexOf($ids,$stage)
            $ids[$idx+1] | Should -Be ($stage+'-reboot')
            $wf.Steps[$idx].Mode | Should -Be 'Detached'
        }
    }
    It 'loads generated task helpers without sidecars before rejecting an unsafe fixture workspace' {
        $c=New-PASConfigurationTemplate -Template FullLab -Path (Join-Path $TestDrive 'closure.json') -WhatIf
        $media=Join-Path $TestDrive 'media.zip'; Set-Content $media 'preflight fixture'
        foreach($type in @('PVWA','CPM','PSM')){
            $part=@($c.components | Where-Object type -eq $type)[0]; $part.media=$media
            $path=& (Get-Module PASeasyInstall) {param($part,$value,$dir) New-PASComponentWorkflow -Component $part -Configuration $value -RunDirectory $dir} $part $c $TestDrive
            $task=Join-Path (Split-Path (Split-Path $path)) 'Task.ps1'
            $settings=@{Id=$part.id;Type=$type;StageRoot=$TestDrive;MediaTarget=$media;Options=@{}}
            $result=& (Join-Path $root 'PASeasyInstall/Private/Engine/Assets/TaskHost.ps1') -Code ([IO.File]::ReadAllText($task)) -Parameters @{Stage='Preflight';Settings=$settings} -Contract Object
            $result.Ok | Should -BeFalse
            $result.Error | Should -Match 'outside its owned boundary'
            $result.Error | Should -Not -Match 'cannot find path|Vendor.ps1|Workspace.ps1'
        }
    }

}
