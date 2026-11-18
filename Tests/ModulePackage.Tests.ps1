BeforeAll {
    # Pester's synthetic TestDrive may be permissive; only tighten our own fixture.
    if($env:OS -ne 'Windows_NT'){& chmod 700 -- $TestDrive;if($LASTEXITCODE -ne 0){throw 'Cannot protect owned package fixture'}}
    $root=Split-Path -Parent $PSScriptRoot
    $builder=Join-Path $root 'Tools/Build-ModulePackage.ps1'
    . (Join-Path $root 'Tools/Packaging.Common.ps1')
    $git=(Get-Command git -CommandType Application|Select-Object -First 1).Source
    function Invoke-FixtureGit {
        param([string]$Directory,[string[]]$Arguments)
        $value=@(& $git -C $Directory @Arguments 2>&1)
        if($LASTEXITCODE -ne 0){throw 'Synthetic Git fixture operation failed'}
        return $value
    }
    function New-PackageFixture {
        $repository=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null=New-Item $repository -ItemType Directory
        Copy-Item (Join-Path $root 'PASeasyInstall') (Join-Path $repository 'PASeasyInstall') -Recurse
        $null=Invoke-FixtureGit $repository @('init','--quiet')
        $null=Invoke-FixtureGit $repository @('config','core.autocrlf','false')
        $null=Invoke-FixtureGit $repository @('config','user.name','PASeasy package test')
        $null=Invoke-FixtureGit $repository @('config','user.email','package-fixture@invalid.local')
        $null=Invoke-FixtureGit $repository @('add','-f','PASeasyInstall')
        $null=Invoke-FixtureGit $repository @('commit','--quiet','-m','Synthetic source fixture')
        return $repository
    }
}
Describe 'Committed-source local module packaging security' {

    It 'creates a private output boundary and rejects staged byte substitution before code import' {
        $output=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-PASeasyPackagePrivateOutput $output|Should -BeExactly $output
        if($env:OS -eq 'Windows_NT'){
            $acl=Get-Acl $output
            $acl.AreAccessRulesProtected|Should -BeTrue
            $allowed=@([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544')
            foreach($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){$ace.IdentityReference.Value|Should -BeIn $allowed}
        }else{
            (& stat -c '%u %a' -- $output)|Should -BeExactly (([string](& id -u))+' 700')
        }
        {New-PASeasyPackagePrivateOutput $output}|Should -Throw '*already exists*'
        $path=Join-Path $output 'PASeasyInstall.psm1'
        [IO.File]::WriteAllText($path,'# ORIGINAL')
        if($env:OS -ne 'Windows_NT'){& chmod 600 -- $path}
        $files=@(@{Relative='PASeasyInstall.psm1';Bytes=(Get-Item $path).Length;SHA256=(Get-FileHash $path).Hash})
        Assert-PASeasyPackageStagedFiles $output $files
        [IO.File]::WriteAllText($path,'# MODIFIED')
        {Assert-PASeasyPackageStagedFiles $output $files}|Should -Throw '*bytes changed*'
    }
    It 'refuses an untrusted writable NTFS ancestor before output creation or frozen import' -Skip:($env:OS -ne 'Windows_NT') {
        $parent=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null=New-Item $parent -ItemType Directory
        $acl=Get-Acl $parent
        $ace=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'Modify','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($ace);Set-Acl -LiteralPath $parent -AclObject $acl
        $before=(Get-Acl $parent).Sddl
        $output=Join-Path $parent 'must-not-exist'
        {New-PASeasyPackagePrivateOutput $output}|Should -Throw '*untrusted modification*'
        Test-Path $output|Should -BeFalse
        (Get-Acl $parent).Sddl|Should -BeExactly $before
        # The actual builder must fail at this boundary before calling its frozen importer.
        $repository=New-PackageFixture
        $sentinel=Join-Path $TestDrive 'unsafe-source-imported.txt'
        $escaped=$sentinel.Replace("'","''")
        Add-Content (Join-Path $repository 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psm1') ("`n[IO.File]::WriteAllText('"+$escaped+"','UNEXPECTED_IMPORT')")
        $null=Invoke-FixtureGit $repository @('add','-f','Modules/PASeasyInstall.Core/PASeasyInstall.Core.psm1')
        $null=Invoke-FixtureGit $repository @('commit','--quiet','-m','Synthetic frozen-import sentinel')
        {& $builder -RepositoryRoot $repository -OutputDirectory $output -StageOnly}|Should -Throw '*untrusted modification*'
        Test-Path $sentinel|Should -BeFalse
        Test-Path $output|Should -BeFalse
    }
    It 'refuses a junction output ancestor without following it' -Skip:($env:OS -ne 'Windows_NT') {
        $target=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $junction=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null=New-Item $target -ItemType Directory
        $null=New-Item $junction -ItemType Junction -Target $target
        try{{New-PASeasyPackagePrivateOutput (Join-Path $junction 'output')}|Should -Throw '*reparse*'}finally{[IO.Directory]::Delete($junction)}
        @(Get-ChildItem $target -Force).Count|Should -Be 0
    }
    It 'refuses nonsticky writable Unix ancestors without repairing them' -Skip:($env:OS -eq 'Windows_NT') {
        $parent=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null=New-Item $parent -ItemType Directory
        & chmod 777 -- $parent
        try{
            {New-PASeasyPackagePrivateOutput (Join-Path $parent 'output')}|Should -Throw '*writable Unix ancestor*'
            (& stat -c '%a' -- $parent)|Should -BeExactly '777'
        }finally{& chmod 700 -- $parent}
    }
    It 'allows runtime source and attribution while refusing media, secrets, runtime configs and legacy controllers' {
        foreach($path in @('Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1','Modules/PASeasyInstall.Core/Data/LogSources.json','Modules/PASeasyInstall.Vault/Recipes/Vault/Workflows/VaultPrimaryOnly.psd1','Modules/PASeasyInstall.Core/Private/V2/Configuration.ps1','Modules/PASeasyInstall.UI/Legacy/Credentials.ps1')){Test-PASeasyPackageSourcePath $path|Should -BeTrue}
        foreach($path in @('PASeasyInstall/keys.zip','PASeasyInstall/license.xml','PASeasyInstall/key.pfx','Modules/PASeasyInstall.Core/Data/credentials.json','PASeasyInstall/Controllers/Invoke-Deployment.ps1','Modules/PASeasyInstall.Core/Private/../outside.ps1','Modules/PASeasyInstall.Vault/Recipes/Vault/operator.xml')){Test-PASeasyPackageSourcePath $path|Should -BeFalse}
        {Assert-PASeasyPackageLocalPath 'https://example.invalid/feed'}|Should -Throw '*local filesystem*'
        {Assert-PASeasyPackageLocalPath '\\example.invalid\feed'}|Should -Throw '*local filesystem*'
    }
    It 'hashes public file inventories with ordinal ordering across platform punctuation/culture differences' {
        $files=@(@{Relative='VaultDR.psd1';SHA256=('a'*64)},@{Relative='VaultDR-Phase2.psd1';SHA256=('b'*64)},@{Relative='VaultDR-Phase1.psd1';SHA256=('c'*64)})
        $text='VaultDR-Phase1.psd1='+('c'*64)+"`n"+'VaultDR-Phase2.psd1='+('b'*64)+"`n"+'VaultDR.psd1='+('a'*64)
        (Get-PASeasyPackageInventoryDigest $files)|Should -BeExactly (Get-PASeasyPackageHash ([Text.Encoding]::UTF8.GetBytes($text)))
        (Get-PASeasyPackageInventoryDigest @($files[2],$files[0],$files[1]))|Should -BeExactly (Get-PASeasyPackageInventoryDigest $files)
    }
    It 'exports committed bytes and excludes dirty tracked files and untracked private artifacts' {
        $repository=New-PackageFixture
        $relative='Modules/PASeasyInstall.Core/Recipes/WindowsComponent/Task.ps1'
        $before=(Get-FileHash (Join-Path $repository $relative)).Hash
        Add-Content (Join-Path $repository $relative) "`n# SYNTHETIC_UNCOMMITTED_SOURCE"
        [IO.File]::WriteAllText((Join-Path $repository 'PASeasyInstall/untracked.pfx'),'SYNTHETIC_UNTRACKED_PRIVATE_INPUT')
        $output=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $result=& $builder -RepositoryRoot $repository -OutputDirectory $output -StageOnly
        $result.Result|Should -BeExactly StagedTrackedSource
        $result.WorkingTreeDirtyIgnored|Should -BeTrue
        (Get-FileHash (Join-Path $result.Stage 'Recipes/WindowsComponent/Task.ps1')).Hash|Should -BeExactly $before
        Test-Path (Join-Path $result.Stage 'untracked.pfx')|Should -BeFalse
        Test-Path (Join-Path $output 'feed')|Should -BeFalse
        {& $builder -RepositoryRoot $repository -OutputDirectory $output -StageOnly}|Should -Throw '*already exists*'
    }
    It 'preserves committed bytes when the repository enables Windows CRLF conversion' {
        $repository=New-PackageFixture
        $relative='PASeasyInstall/Recipes/LinuxComponent/Task.sh'
        $expected=(Get-FileHash (Join-Path $repository $relative)).Hash
        $null=Invoke-FixtureGit $repository @('config','core.autocrlf','true')
        $null=Invoke-FixtureGit $repository @('config','core.eol','crlf')
        $output=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $result=& $builder -RepositoryRoot $repository -OutputDirectory $output -StageOnly
        (Get-FileHash (Join-Path $result.Stage 'Recipes/LinuxComponent/Task.sh')).Hash|Should -BeExactly $expected
        ([string](Invoke-FixtureGit $repository @('config','core.autocrlf')))|Should -BeExactly 'true'
        ([string](Invoke-FixtureGit $repository @('config','core.eol')))|Should -BeExactly 'crlf'
    }
    It 'refuses a tracked operator config before creating package output' {
        $repository=New-PackageFixture
        [IO.File]::WriteAllText((Join-Path $repository 'PASeasyInstall/operator.json'),'SYNTHETIC_OPERATOR_INPUT')
        $null=Invoke-FixtureGit $repository @('add','-f','PASeasyInstall/operator.json')
        $null=Invoke-FixtureGit $repository @('commit','--quiet','-m','Synthetic prohibited config')
        $output=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        {& $builder -RepositoryRoot $repository -OutputDirectory $output -StageOnly}|Should -Throw '*outside the package allowlist*'
        Test-Path $output|Should -BeFalse
    }
    It 'refuses private material even when planted in an otherwise allowed source file' {
        $repository=New-PackageFixture
        Add-Content (Join-Path $repository 'Modules/PASeasyInstall.Core/Recipes/WindowsComponent/Task.ps1') "`n# -----BEGIN PRIVATE KEY-----"
        $null=Invoke-FixtureGit $repository @('add','-f','PASeasyInstall')
        $null=Invoke-FixtureGit $repository @('commit','--quiet','-m','Synthetic private marker')
        $output=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        {& $builder -RepositoryRoot $repository -OutputDirectory $output -StageOnly}|Should -Throw '*private key material*'
        Test-Path (Join-Path $output 'feed')|Should -BeFalse
    }
    It 'rejects committed symlink metadata without following the target' {
        $repository=New-PackageFixture
        $blob=[string](Invoke-FixtureGit $repository @('rev-parse','HEAD:PASeasyInstall/LICENSE.txt'))
        $null=Invoke-FixtureGit $repository @('update-index','--add','--cacheinfo',('120000,'+$blob+',Modules/PASeasyInstall.Core/Private/planted.ps1'))
        $null=Invoke-FixtureGit $repository @('commit','--quiet','-m','Synthetic symlink metadata')
        $output=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        {& $builder -RepositoryRoot $repository -OutputDirectory $output -StageOnly}|Should -Throw '*outside the package allowlist*'
        Test-Path $output|Should -BeFalse
    }
}
