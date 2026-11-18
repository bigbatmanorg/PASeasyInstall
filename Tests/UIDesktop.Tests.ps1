# New desktop (UI v1.0) and its real backend seam. No window, no server, no vendor execution:
# synthetic media in TestDrive; engine runs are mocked where the fleet scheduler is exercised.
BeforeAll {
    $repo=Split-Path -Parent $PSScriptRoot
    $modules=Join-Path $repo 'Modules'
    $env:PAS_EASY_DATA_ROOT=Join-Path $TestDrive 'data'
    Import-Module (Join-Path $modules 'PASeasyInstall.Orchestrator/PASeasyInstall.Orchestrator.psd1') -Force
    Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    function New-TestZip([string]$Path,[string[]]$Entries){
        $dir=[IO.Path]::GetDirectoryName($Path); if(-not(Test-Path $dir)){New-Item -ItemType Directory $dir -Force|Out-Null}
        $fs=[IO.File]::Open($Path,[IO.FileMode]::Create)
        $zip=New-Object IO.Compression.ZipArchive($fs,[IO.Compression.ZipArchiveMode]::Create)
        try{foreach($e in $Entries){$w=New-Object IO.StreamWriter($zip.CreateEntry($e).Open());$w.Write('synthetic '+$e);$w.Dispose()}}finally{$zip.Dispose();$fs.Dispose()}
    }
    $media=Join-Path $TestDrive 'media'
    New-TestZip (Join-Path $media 'CorePAS/Vault/Server-Rls-v15.0.zip') @('setup.exe')
    New-TestZip (Join-Path $media 'CorePAS/Vault/PACLI-Rls-v15.0.zip') @('pacli.exe')
    New-TestZip (Join-Path $media 'CorePAS/Vault/Disaster Recovery-Rls-v15.0.zip') @('setup.exe')
    New-TestZip (Join-Path $media 'CorePAS/Password Vault Web Access/Password Vault Web Access-Rls-v15.0.zip') @('x')
    New-TestZip (Join-Path $media 'keys.zip') @('master/recpub.key','master/recprv.key')
    # Bundle: CPM/PSM/PSMP only inside; PVWA also loose (duplicate must be dropped).
    New-TestZip (Join-Path $media 'Privileged Access Manager Self-Hosted_15.0.zip') @(
        'CorePAS/Password Vault Web Access/Password Vault Web Access-Rls-v15.0.zip',
        'CorePAS/Central Policy Manager/Central Policy Manager-Rls-v15.0.zip',
        'CorePAS/Privileged Session Manager/Privileged Session Manager-Rls-v15.0.zip',
        'CorePAS/Privileged Session Manager for SSH/PrivilegedSessionManagerSSHProxy-RHELinux9-Intel64-Rls-v15.0.zip',
        'CorePAS/Privileged Session Manager for SSH/PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.0.zip',
        'CorePAS/Vault/Vault Ansible Role-Rls-v15.0.zip')
    [IO.File]::WriteAllText((Join-Path $media 'license.xml'),'<license/>')
    [IO.File]::WriteAllText((Join-Path $media 'VC_redist.x86.exe'),'x')
    $script:inventory=@(Get-PASMediaInventory -Path $media)
    $script:selection=Get-PASMediaSelection -Inventory $script:inventory
    $script:lab=@(@{Type='PVWA';Name='PAS-PVWA';Address='192.0.2.33'},@{Type='CPM';Name='PAS-CPM';Address='192.0.2.34'},
        @{Type='PSM';Name='PAS-PSM';Address='192.0.2.35'},@{Type='PSMP';Name='PAS-PSMP';Address='192.0.2.36'})
    function New-LabConfig([string]$Mode='Parallel',[string]$Profile='Lab',[switch]$NoEula,[object[]]$Instances=$script:lab){
        New-PASDeploymentConfiguration -Environment MyPAM -VaultMode PrimaryDR -Instances $Instances -ControllerAddress 198.51.100.250 `
            -PrimaryAddress 192.0.2.31 -DRAddress 192.0.2.32 -Media $script:selection -ExecutionMode $Mode -SecurityProfile $Profile -AcceptEula:(-not $NoEula)
    }
}
AfterAll { Remove-Item Env:\PAS_EASY_DATA_ROOT -ErrorAction SilentlyContinue }

Describe 'UI backend contract' {
    It 'is satisfied by the real Orchestrator and by the Mock' {
        . (Join-Path $modules 'PASeasyInstall.UI/Backend/Backend.Contract.ps1')
        { Assert-PASUIBackend } | Should -Not -Throw
        $mock=Import-Module (Join-Path $modules 'PASeasyInstall.UI/Backend/Mock/PASeasyInstall.Mock.psd1') -PassThru -Force
        try{
            foreach($name in (Get-PASUIBackendContract).Keys){
                $cmd=Get-Command -Module PASeasyInstall.Mock -Name $name
                foreach($p in (Get-PASUIBackendContract)[$name]){ $cmd.Parameters.ContainsKey($p) | Should -BeTrue -Because "$name -$p" }
            }
        } finally { Remove-Module $mock; Import-Module (Join-Path $modules 'PASeasyInstall.Orchestrator/PASeasyInstall.Orchestrator.psd1') -Force }
    }
    It 'keeps one media inventory implementation for both backends' {
        $a=Get-FileHash (Join-Path $modules 'PASeasyInstall.Orchestrator/Private/MediaInventory.ps1')
        $b=Get-FileHash (Join-Path $modules 'PASeasyInstall.UI/Backend/MediaInventory.ps1')
        $a.Hash | Should -Be $b.Hash
    }
    It 'stores non-ASCII PowerShell sources as UTF-8 with BOM (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        foreach($f in @(Get-ChildItem -LiteralPath $modules -Recurse -File|Where-Object {$_.Extension -in @('.ps1','.psm1','.psd1')})){
            $bytes=[IO.File]::ReadAllBytes($f.FullName)
            $nonAscii=@($bytes|Where-Object {$_ -gt 127}).Count -gt 0
            if($nonAscii){ ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue -Because $f.FullName }
        }
    }
    It 'defaults the desktop to the real installer' {
        (Get-Content (Join-Path $repo 'Start-PASeasyInstall.ps1') -Raw) | Should -Match "\`$Backend='Orchestrator'"
        (Get-Content (Join-Path $modules 'PASeasyInstall.UI/App.ps1') -Raw) | Should -Match "\`$Backend='Orchestrator'"
    }
}

Describe 'Media inventory and selection' {
    It 'finds plain files and bundle entries without extracting, and drops bundle copies of plain files' {
        @($script:inventory|Where-Object {$_.Component -eq 'PVWA'}).Count | Should -Be 1
        @($script:inventory|Where-Object {$_.Component -eq 'PVWA'})[0].Entry | Should -BeNullOrEmpty
        @($script:inventory|Where-Object {$_.Component -eq 'CPM'})[0].Entry | Should -Match 'Central Policy Manager'
        @($script:inventory|Where-Object {$_.Component -eq 'PSMP'}).Count | Should -Be 2
        @($script:inventory|Where-Object {$_.Component -eq 'Prerequisite'}).Count | Should -Be 1
        @($script:inventory|Where-Object {$_.Name -match 'Ansible'}).Count | Should -Be 0
        @(Get-ChildItem (Join-Path $env:PAS_EASY_DATA_ROOT 'MediaCache') -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
    It 'recommends Ubuntu24 PSMP and the recovery key from the key archive' {
        $script:selection.PSMP.Variant | Should -Be 'Ubuntu24'
        $script:selection.RecoveryKey.Entry | Should -Be 'master/recpub.key'
        $script:selection.License.Name | Should -Be 'license.xml'
    }
}

Describe 'Deployment composition' {
    BeforeAll { $script:c=New-LabConfig; $script:v=Test-PASEnvironment -Configuration $script:c }
    It 'composes one valid Primary + DR + four component configuration' {
        $script:v.Issues | Should -BeNullOrEmpty
        $script:v.Valid | Should -BeTrue
        @($script:c.components|ForEach-Object {$_.id}) | Should -Be @('vault','dr','pas-pvwa','pas-cpm','pas-psm','pas-psmp')
        @($script:c.components|ForEach-Object {$_.name})[2] | Should -Be 'PAS-PVWA'
        $script:c.execution.mode | Should -Be 'Parallel'
        $script:c.hosts['vault01'].user | Should -Be 'Administrator'
    }
    It 'extracts only selected bundle entries into the media cache, and only the public recovery key' {
        $cpm=@($script:c.components|Where-Object {$_.type -eq 'CPM'})[0]
        $cpm.media | Should -Match 'MediaCache'
        Test-Path -LiteralPath $cpm.media | Should -BeTrue
        $script:c.media.PublicRecoveryKey | Should -Match 'recpub\.key$'
        @(Get-ChildItem (Join-Path $env:PAS_EASY_DATA_ROOT 'MediaCache') -Recurse -File|Where-Object Name -eq 'recprv.key').Count | Should -Be 0
        $script:c.media.ServerZip | Should -Match 'Server-Rls-v15.0.zip$'
    }
    It 'records the lab deviations a template-built lab needs, and none in Secure' {
        $o=$script:c.security.overrides
        foreach($k in 'WinRM.SkipCACheck','WinRM.SkipCNCheck','Vault.AllowRDP','CPM.AllowPinnedLeafTrust'){ $o[$k] | Should -BeTrue }
        $secure=New-LabConfig -Profile Secure
        @($secure.security.overrides.Keys).Count | Should -Be 0
        @($secure.components|Where-Object {$_.type -eq 'CPM'})[0].options.Contains('pvwaTrustFrom') | Should -BeFalse
    }
    It 'wires PVWA lab certificate, CPM pinning and PSMP EULA and SSH identity' {
        $pvwa=@($script:c.components|Where-Object {$_.type -eq 'PVWA'})[0]
        $pvwa.options.createLabCertificate | Should -BeTrue
        $pvwa.options.pvwaUrl | Should -Be 'https://PAS-PVWA/PasswordVault'
        @($script:c.components|Where-Object {$_.type -eq 'CPM'})[0].options.pvwaTrustFrom | Should -Be 'pas-pvwa'
        @($script:c.components|Where-Object {$_.type -eq 'PSMP'})[0].options.acceptEula | Should -BeTrue
        $script:c.hosts['pas-psmp'].identityFile | Should -Match 'ssh.mypam.id_ed25519$'
    }
    It 'refuses PSMP without EULA acceptance' {
        $v=Test-PASEnvironment -Configuration (New-LabConfig -NoEula)
        $v.Valid | Should -BeFalse
        ($v.Issues -join ';') | Should -Match 'EULA'
    }
    It 'co-locates instances that share an address on one server named after the first' {
        $c=New-LabConfig -Instances @(@{Type='PVWA';Name='PVWA01';Address='192.0.2.40'},@{Type='CPM';Name='CPM01';Address='192.0.2.40'})
        @($c.hosts.Keys) | Should -Contain 'pvwa01'
        @($c.hosts.Keys) | Should -Not -Contain 'cpm01'
        @($c.components|Where-Object {$_.type -eq 'CPM'})[0].host | Should -Be 'pvwa01'
    }
    It 'never reuses engine journal names as instance ids' {
        $c=New-LabConfig -Instances @(@{Type='PVWA';Name='primary';Address='192.0.2.40'})
        @($c.components|Where-Object {$_.type -eq 'PVWA'})[0].id | Should -Not -Be 'primary'
    }
    It 'enriches plan items for the review and keeps the execution mode' {
        $p=Get-PASEnvironmentPlan -Configuration $script:c
        $p.ExecutionMode | Should -Be 'Parallel'
        $item=@($p.Items|Where-Object {$_.Type -eq 'PVWA'})[0]
        $item.Name | Should -Be 'PAS-PVWA'; $item.Address | Should -Be '192.0.2.33'; $item.Media | Should -Be 'Password Vault Web Access-Rls-v15.0.zip'
        @($p.Items|Where-Object {$_.Type -eq 'Vault'})[0].Media | Should -Be 'Server-Rls-v15.0.zip'
    }
    It 'saves and reloads to the same reviewed plan digest' {
        $path=Join-Path $TestDrive 'project.json'
        $saved=Save-PASEnvironment -Configuration $script:c -Path $path -Force
        $reloaded=Test-PASEnvironment -Config $saved
        (Get-PASEnvironmentPlan -Configuration $reloaded.Configuration).ConfigDigest | Should -Be (Get-PASEnvironmentPlan -Configuration $script:c).ConfigDigest
    }
}

Describe 'Composed deployment runner' {
    BeforeAll { $script:m=Get-Module PASeasyInstall.Orchestrator }
    It 'turns a WinRM user into an explicit local account only for Windows servers' {
        $pw=ConvertTo-SecureString 'synthetic' -AsPlainText -Force
        $map=@{'pas-pvwa'=[pscredential]::new('Administrator',$pw);'pas-psmp'=[pscredential]::new('root',$pw);'vault01'=[pscredential]::new('LAB\admin',$pw)}
        $out=& $script:m {param($c,$m) ConvertTo-PASControllerCredentialMap $c $m} (Test-PASEnvironment -Configuration (New-LabConfig)).Configuration $map
        $out['pas-pvwa'].UserName | Should -Be '.\Administrator'
        $out['pas-psmp'].UserName | Should -Be 'root'
        $out['vault01'].UserName | Should -Be 'LAB\admin'
    }
    It 'splits the deployment into Vault first, then one unit per instance, CPM after its PVWA' {
        $units=& $script:m {param($c) Get-PASFleetUnits $c} (Test-PASEnvironment -Configuration (New-LabConfig)).Configuration
        @($units|ForEach-Object {$_.id}) | Should -Be @('vault','pas-pvwa','pas-cpm','pas-psm','pas-psmp')
        @($units[2].dependsOn) | Should -Be @('vault','pas-pvwa')
        @($units[0].hosts) | Should -Be @('vault01','dr01')
    }
    It 'builds valid existing-Vault child configurations with the captured PVWA pin' {
        $c=(Test-PASEnvironment -Configuration (New-LabConfig)).Configuration
        $cer=Join-Path $TestDrive 'pin.cer'; [IO.File]::WriteAllBytes($cer,[byte[]](1..20))
        $trust=@{'pas-pvwa'=@{File=$cer;SHA256=(Get-FileHash $cer).Hash}}
        $units=& $script:m {param($c) Get-PASFleetUnits $c} $c
        foreach($u in $units){
            $child=& $script:m {param($c,$u,$t) New-PASFleetChildConfiguration -Configuration $c -Unit $u -Trust $t} $c $u $trust
            $child.Contains('execution') | Should -BeFalse
            if($u.id -ne 'vault'){
                $child.vault.existing | Should -BeTrue
                $child.name | Should -Be ('MyPAM-'+$u.id)
                (Test-PASEnvironment -Configuration $child -CheckMedia).Valid | Should -BeTrue -Because $u.id
            }
        }
        $cpm=& $script:m {param($c,$u,$t) New-PASFleetChildConfiguration -Configuration $c -Unit $u -Trust $t} $c $units[2] $trust
        $cpm.components[0].options.pvwaTrustCertificateSHA256 | Should -Be $trust['pas-pvwa'].SHA256
        $cpm.components[0].options.Contains('pvwaTrustFrom') | Should -BeFalse
        $psmp=& $script:m {param($c,$u,$t) New-PASFleetChildConfiguration -Configuration $c -Unit $u -Trust $t} $c $units[4] $trust
        @($psmp.security.overrides.Keys).Count | Should -Be 0
    }
    Context 'scheduling (engine runs mocked)' {
        BeforeEach {
            $script:launches=New-Object System.Collections.ArrayList
            $script:polls=@{}
            Mock -ModuleName PASeasyInstall.Orchestrator Start-Sleep {}
            Mock -ModuleName PASeasyInstall.Orchestrator Test-PASeasyConfig { [pscustomobject]@{Valid=$true;Issues=@();Warnings=@();Configuration=$Configuration} }
            Mock -ModuleName PASeasyInstall.Orchestrator Invoke-PASSshBootstrap {}
            Mock -ModuleName PASeasyInstall.Orchestrator Get-PASFleetPVWACertificate { @{File='pin.cer';SHA256=('A'*64)} }
            Mock -ModuleName PASeasyInstall.Orchestrator Start-PASeasyDeployment {
                $running=@($script:polls.Keys|Where-Object {$script:polls[$_] -lt 2})
                [void]$script:launches.Add([pscustomobject]@{Unit=[string]$Configuration.components[-1].id;RunningAtLaunch=$running})
                $id=[guid]::NewGuid().ToString('N'); $script:polls[$id]=0; $id
            }
            Mock -ModuleName PASeasyInstall.Orchestrator Get-PASeasyRun {
                $script:polls[$RunId]++
                [pscustomobject]@{status=$(if($script:polls[$RunId] -ge 2){'Succeeded'}else{'Running'});message='synthetic'}
            }
        }
        It 'Sequential: one unit at a time, in plan order' {
            $id=& $script:m {param($c) Start-PASFleet -Configuration $c -Foreground} (Test-PASEnvironment -Configuration (New-LabConfig -Mode Sequential)).Configuration
            @($script:launches|ForEach-Object Unit) | Should -Be @('dr','pas-pvwa','pas-cpm','pas-psm','pas-psmp')
            foreach($l in $script:launches){ @($l.RunningAtLaunch).Count | Should -Be 0 }
            (Get-PASEnvironmentSnapshot -RunId $id).Status | Should -Be 'Succeeded'
        }
        It 'Parallel: Vault first, then all servers at once, CPM after its PVWA' {
            $id=& $script:m {param($c) Start-PASFleet -Configuration $c -Foreground} (Test-PASEnvironment -Configuration (New-LabConfig -Mode Parallel)).Configuration
            $order=@($script:launches|ForEach-Object Unit)
            $order[0] | Should -Be 'dr'
            @($script:launches[0].RunningAtLaunch).Count | Should -Be 0
            $psmLaunch=@($script:launches|Where-Object Unit -eq 'pas-psmp')[0]
            @($psmLaunch.RunningAtLaunch).Count | Should -BeGreaterThan 0
            [array]::IndexOf($order,'pas-cpm') | Should -BeGreaterThan ([array]::IndexOf($order,'pas-pvwa'))
            $snap=Get-PASEnvironmentSnapshot -RunId $id
            $snap.Status | Should -Be 'Succeeded'
            @($snap.Units|Where-Object Status -ne 'Succeeded').Count | Should -Be 0
            @($snap.Events|Where-Object {$_.Stage -eq 'LocalPreflight' -and $_.Status -eq 'Complete'}).Count | Should -Be 6
        }
        It 'stops starting units after a failure and reports it' {
            Mock -ModuleName PASeasyInstall.Orchestrator Get-PASeasyRun {
                $script:polls[$RunId]++
                $first=@($script:polls.Keys)[0]
                [pscustomobject]@{status=$(if($script:polls[$RunId] -ge 2){'Failed'}else{'Running'});message='synthetic failure'}
            }
            $id=& $script:m {param($c) Start-PASFleet -Configuration $c -Foreground} (Test-PASEnvironment -Configuration (New-LabConfig -Mode Parallel)).Configuration
            @($script:launches).Count | Should -Be 1
            $snap=Get-PASEnvironmentSnapshot -RunId $id
            $snap.Status | Should -Be 'Failed'
            @($snap.Units|Where-Object Status -eq 'Skipped').Count | Should -Be 4
        }
    }
    It 'maps the Vault engine journal names onto the plan ids' {
        & $script:m {ConvertTo-PASUIComponentId 'primary_final'} | Should -Be 'vault'
        & $script:m {ConvertTo-PASUIComponentId 'dr_final'} | Should -Be 'dr'
        & $script:m {ConvertTo-PASUIComponentId 'pas-cpm'} | Should -Be 'pas-cpm'
    }
}

Describe 'Desktop renderers' {
    BeforeAll { . (Join-Path $modules 'PASeasyInstall.UI/Presentation.ps1') }
    It 'never lets an informational line downgrade a completed stage' {
        $snap=[pscustomobject]@{RunId=('c'*32);Status='Running';CurrentComponent='vault';LastStep='install-server';ErrorEvents=0;Events=@(
            [pscustomobject]@{TimestampUtc='2026-11-18T12:00:00Z';Status='Complete';Component='vault';Stage='install-server';Event='TaskCompleted';Message='done'},
            [pscustomobject]@{TimestampUtc='2026-11-18T12:00:01Z';Status='Info';Component='vault';Stage='install-server';Event='AttemptState';Message='remote attempt is Succeeded'})}
        $item=[pscustomobject]@{Id='vault';Type='Vault';Host='vault01';Address='192.0.2.31'}
        $html=ConvertTo-PASUIDashboardHtml -Snapshot $snap -PlanItems @($item) -Catalog @{Vault=@('install-server')}
        $html | Should -Match 'pas-chip complete">install-server'
    }
    It 'escapes plan values in the review table' {
        $plan=[pscustomobject]@{ConfigDigest='d'*64;ExecutionMode='Sequential';Warnings=@();ExistingVault='';Items=@([pscustomobject]@{Id='x';Name='<b>x</b>';Type='PVWA';Host='h';Address='a';Media='m';DependsOn=@()})}
        $html=ConvertTo-PASUIReviewHtml -Validation ([pscustomobject]@{Valid=$true;Issues=@()}) -Plan $plan -StageCounts @{PVWA=11}
        $html | Should -Not -Match '<b>x</b>'
        $html | Should -Match '&lt;b&gt;x&lt;/b&gt;'
    }
}
