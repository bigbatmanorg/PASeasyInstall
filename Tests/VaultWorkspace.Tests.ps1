BeforeAll {
    $repo=Split-Path -Parent $PSScriptRoot
    $common=Join-Path $repo 'Modules/PASeasyInstall.Vault/Recipes/Vault/Tasks/Common'
    $ownership=Get-Content (Join-Path $repo 'Modules/PASeasyInstall.Core/Recipes/WindowsComponent/Ownership.ps1') -Raw
    $workspace=Get-Content (Join-Path $common 'VaultWorkspace.ps1') -Raw
    . ([scriptblock]::Create($ownership))
    . ([scriptblock]::Create($workspace))
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function New-VaultZip($Path,$Entries){
        $zip=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
        try{foreach($record in $Entries){$entry=$zip.CreateEntry($record.Name);if($record.ContainsKey('Mode')){$entry.ExternalAttributes=[int]$record.Mode -shl 16};$stream=$entry.Open();try{$bytes=[Text.Encoding]::UTF8.GetBytes($record.Body);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}}}finally{$zip.Dispose()}
    }
    function Set-VaultFixtureFile($Path,$Body){Write-PASeasyVaultOwnedFile $Path ([Text.Encoding]::UTF8.GetBytes($Body)) -CreateNew}
    function Invoke-VaultFixtureTask($Name,$Settings,$Components){
        $text=(Get-Content (Join-Path $common $Name) -Raw).Replace('# PAEASY_INCLUDE_VAULT_WORKSPACE',($ownership+[char]10+$workspace))
        & ([scriptblock]::Create($text)) -Settings $Settings -Components $Components
    }
}
Describe 'Vault workspace stable ownership and hostile filesystem admission' {
    BeforeEach {
        $fixture=Join-Path $env:SystemDrive ('PAeasyVaultWorkspaceQualification-'+[guid]::NewGuid().ToString('N'))
        New-PASeasyVaultDirectory $fixture
        $settings=@{PackagesRoot=(Join-Path $fixture 'packages')}
        New-PASeasyVaultDirectory $settings.PackagesRoot
    }
    AfterEach {
        if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
    }
    It 'creates protected stable directories and files while restoring token privilege' {
        $before=(Get-PASeasyRestorePrivilegeState).Attributes
        $nested=Join-Path $settings.PackagesRoot 'new\nested';New-PASeasyVaultDirectory $nested
        $file=Join-Path $nested 'data';Set-VaultFixtureFile $file 'fixture'
        Assert-PASeasyVaultTree $fixture -Protected
        (Get-Acl $file).GetOwner([Security.Principal.SecurityIdentifier]).Value|Should -Be 'S-1-5-32-544'
        (Get-PASeasyRestorePrivilegeState).Attributes|Should -Be $before
    }
    It 'refuses a transient/orphan owner without changing its ACL or bytes' {
        $file=Join-Path $settings.PackagesRoot 'untrusted';Set-VaultFixtureFile $file 'unchanged'
        $acl=Get-Acl $file;$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-94-1'))
        Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($file)).SetAccessControl($acl)}
        $before=(Get-Acl $file).Sddl
        {Write-PASeasyVaultOwnedFile $file ([byte[]]@(1))}|Should -Throw '*owner*'
        (Get-Acl $file).Sddl|Should -BeExactly $before
        [IO.File]::ReadAllText($file)|Should -BeExactly 'unchanged'
    }
    It 'rejects an untrusted app writer before hashing media' {
        $acl=Get-Acl $settings.PackagesRoot;$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'FullControl','Allow'))
        ([IO.DirectoryInfo]::new($settings.PackagesRoot)).SetAccessControl($acl)
        Mock Get-FileHash {throw 'Hash must not run'}
        {Expand-PASeasyVaultMedia $settings 'PACLI'}|Should -Throw '*writer*'
        Should -Invoke Get-FileHash -Times 0
    }
    It 'rejects an ancestor DeleteChild grant without repairing the ancestor' {
        $acl=Get-Acl $fixture;$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'DeleteSubdirectoriesAndFiles','Allow'))
        ([IO.DirectoryInfo]::new($fixture)).SetAccessControl($acl);$before=(Get-Acl $fixture).Sddl
        {New-PASeasyVaultDirectory (Join-Path $settings.PackagesRoot 'blocked')}|Should -Throw '*deletion*'
        (Get-Acl $fixture).Sddl|Should -BeExactly $before
    }
    It 'rejects a junction without traversing or changing its target' {
        $outside=Join-Path $fixture 'outside';New-PASeasyVaultDirectory $outside
        $junction=Join-Path $settings.PackagesRoot 'link';New-Item -ItemType Junction -Path $junction -Target $outside|Out-Null
        $before=(Get-Acl $outside).Sddl
        try{{Assert-PASeasyVaultTree $settings.PackagesRoot}|Should -Throw '*reparse*';(Get-Acl $outside).Sddl|Should -BeExactly $before}finally{[IO.Directory]::Delete($junction)}
    }
    It 'fails before creation if the existing restore privilege cannot be enabled' {
        $target=Join-Path $fixture 'not-created'
        Mock Invoke-PASeasyWithRestorePrivilege {throw 'Existing SeRestorePrivilege absent'}
        {New-PASeasyVaultDirectory $target}|Should -Throw '*SeRestorePrivilege*'
        Test-Path $target|Should -BeFalse
    }
    It 'does not chmod/adopt an existing file used as a directory' {
        $file=Join-Path $fixture 'file';Set-VaultFixtureFile $file 'fixture';$before=(Get-Acl $file).Sddl
        {New-PASeasyVaultDirectory $file}|Should -Throw '*directory*'
        (Get-Acl $file).Sddl|Should -BeExactly $before
    }
    It 'rejects unsafe roots and OS workspace boundaries' {
        foreach($path in @('C:\','C:\foo\..\bar','C:\foo.','\\server\share','C:\file:ads')){{Get-PASeasyVaultCanonicalPath $path}|Should -Throw}
        $invalid=@{PackagesRoot='C:\Windows\packages';AutomationRoot='C:\fixture\automation';KeysDir='C:\fixture\keys';DataDrive='C:'}
        {Get-PASeasyVaultWorkspacePaths $invalid}|Should -Throw '*OS*'
    }
}
Describe 'Vault atomic archive admission and pinned completion' {
    BeforeEach {
        $fixture=Join-Path $env:SystemDrive ('PAeasyVaultWorkspaceQualification-'+[guid]::NewGuid().ToString('N'));New-PASeasyVaultDirectory $fixture
        $settings=@{PackagesRoot=(Join-Path $fixture 'packages')};New-PASeasyVaultDirectory $settings.PackagesRoot
        $zip=Join-Path $settings.PackagesRoot 'PACLI-Rls.zip'
        $destination=Join-Path $settings.PackagesRoot 'PACLI'
        $outsideAcl=(Get-Acl ([IO.Path]::GetPathRoot($fixture))).Sddl
    }
    AfterEach {if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
    It 'executes assembled static recipe payloads and verifies stable entry ownership twice' {
        # Create via protected empty BA-owned stub; ZipArchive writes to the same inode.
        Set-VaultFixtureFile $zip ''
        $stream=[IO.File]::Open($zip,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create)
        try{foreach($name in @('Pacli.exe',('nested/library-'+[char]0xe6+'.dll'))){$entry=$archive.CreateEntry($name);$writer=$entry.Open();try{$bytes=[Text.Encoding]::UTF8.GetBytes('fixture');$writer.Write($bytes,0,$bytes.Length)}finally{$writer.Dispose()}}}finally{$archive.Dispose()}
        $first=Invoke-VaultFixtureTask 'Expand-Media.ps1' $settings @('PACLI');$first.Changed|Should -BeTrue
        $second=Invoke-VaultFixtureTask 'Expand-Media.ps1' $settings @('PACLI');$second.Changed|Should -BeFalse
        (Invoke-VaultFixtureTask 'Verify-Media.ps1' $settings @('PACLI')).Passed|Should -BeTrue
        Assert-PASeasyVaultTree $destination -Protected
        (Get-Acl ([IO.Path]::GetPathRoot($fixture))).Sddl|Should -BeExactly $outsideAcl
    }
    It 'rejects hostile entries before creating any destination or partial' -TestCases @(
        @{Name='../escape'},@{Name='C:/escape'},@{Name='//server/share'},@{Name='bad:ads'},@{Name='NUL.txt'},@{Name='trailing.'},@{Name='.paeasy-extracted.json'}
    ) {param($Name)
        # Local test ZIP is newly created by the same elevated fixture owner, then its security is supplied explicitly.
        New-VaultZip $zip @(@{Name='Pacli.exe';Body='safe'},@{Name=$Name;Body='bad'})
        Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($zip)).SetAccessControl((New-PASeasyVaultSecurity $false))}
        {Expand-PASeasyVaultMedia $settings 'PACLI'}|Should -Throw
        Test-Path $destination|Should -BeFalse
        @(Get-ChildItem $settings.PackagesRoot -Force|Where-Object {$_.Name -like '.paeasy-extract-*'}).Count|Should -Be 0
    }
    It 'rejects links, aliases, prefix aliases, shadowing and expanded-size excess' -TestCases @(
        @{Kind='symlink'},@{Kind='duplicate'},@{Kind='prefixcase'},@{Kind='shadow'},@{Kind='size'}
    ) {param($Kind)
        $entries=@(@{Name='Pacli.exe';Body='safe'})
        switch($Kind){'symlink'{$entries+=@{Name='link';Body='target';Mode=40960}}'duplicate'{$entries+=@{Name='PACLI.EXE';Body='alias'}}'prefixcase'{$entries+=@(@{Name='dir/a';Body='a'},@{Name='DIR/b';Body='b'})}'shadow'{$entries+=@(@{Name='dir';Body='a'},@{Name='dir/file';Body='b'})}}
        New-VaultZip $zip $entries;Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($zip)).SetAccessControl((New-PASeasyVaultSecurity $false))}
        if($Kind -eq 'size'){{Expand-PASeasyVaultMedia $settings 'PACLI' -MaxBytes 1}|Should -Throw '*size*'}else{{Expand-PASeasyVaultMedia $settings 'PACLI'}|Should -Throw}
        Test-Path $destination|Should -BeFalse
    }
    It 'limits entry count and removes only its own failed extraction after a write failure' -Tag 'RequiresLabController' {
        New-VaultZip $zip @(@{Name='Pacli.exe';Body='safe'},@{Name='other.dll';Body='fixture'})
        Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($zip)).SetAccessControl((New-PASeasyVaultSecurity $false))}
        {Expand-PASeasyVaultMedia $settings 'PACLI' -MaxFiles 1}|Should -Throw '*count*'
        $keep=Join-Path $settings.PackagesRoot 'operator-file';Set-VaultFixtureFile $keep 'keep'
        Mock Get-FileHash {throw 'Synthetic target hash failure'} -ParameterFilter {$LiteralPath -like '*\.paeasy-extract-*\Pacli.exe'}
        {Expand-PASeasyVaultMedia $settings 'PACLI'}|Should -Throw '*Synthetic*'
        Test-Path $destination|Should -BeFalse
        @(Get-ChildItem $settings.PackagesRoot -Force|Where-Object {$_.Name -like '.paeasy-extract-*'}).Count|Should -Be 0
        [IO.File]::ReadAllText($keep)|Should -BeExactly 'keep'
    }
    It 'retains existing unmarked destinations and partials without deleting contents' {
        New-VaultZip $zip @(@{Name='Pacli.exe';Body='safe'});Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($zip)).SetAccessControl((New-PASeasyVaultSecurity $false))}
        New-PASeasyVaultDirectory ($destination+'.partial');Set-VaultFixtureFile (Join-Path ($destination+'.partial') 'keep') 'keep'
        {Expand-PASeasyVaultMedia $settings 'PACLI'}|Should -Throw '*partial*'
        [IO.File]::ReadAllText((Join-Path ($destination+'.partial') 'keep'))|Should -Be 'keep'
        New-PASeasyVaultDirectory $destination
        {Expand-PASeasyVaultMedia $settings 'PACLI'}|Should -Throw
        Test-Path $destination|Should -BeTrue
    }
    It 'refuses a legacy marker without deleting or adopting its directory' {
        New-VaultZip $zip @(@{Name='Pacli.exe';Body='safe'});Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($zip)).SetAccessControl((New-PASeasyVaultSecurity $false))}
        New-PASeasyVaultDirectory $destination
        $legacy=Join-Path $destination '.pssteps-extracted';Set-VaultFixtureFile $legacy ((Get-FileHash $zip).Hash)
        $before=[IO.File]::ReadAllText($legacy)
        {Expand-PASeasyVaultMedia $settings 'PACLI'}|Should -Throw
        [IO.File]::ReadAllText($legacy)|Should -BeExactly $before
        Test-Path (Join-Path $destination 'Pacli.exe')|Should -BeFalse
    }
    It 'rejects changed source archives and modified extracted files' {
        New-VaultZip $zip @(@{Name='Pacli.exe';Body='safe'});Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($zip)).SetAccessControl((New-PASeasyVaultSecurity $false))}
        Expand-PASeasyVaultMedia $settings 'PACLI'|Should -BeTrue
        $binary=Join-Path $destination 'Pacli.exe';Write-PASeasyVaultOwnedFile $binary ([Text.Encoding]::UTF8.GetBytes('changed'))
        {Test-PASeasyVaultExtractedMedia $settings 'PACLI'}|Should -Throw '*differs*'
        Write-PASeasyVaultOwnedFile $binary ([Text.Encoding]::UTF8.GetBytes('safe'))
        Write-PASeasyVaultOwnedFile $zip ([Text.Encoding]::UTF8.GetBytes('changedzip'))
        {Test-PASeasyVaultExtractedMedia $settings 'PACLI'}|Should -Throw '*marker*'
    }
}

Describe 'Private inherited SYSTEM vendor descendants preserve safe resume' {
    BeforeEach {
        $fixture=Join-Path $env:SystemDrive ('PAeasyVaultWorkspaceQualification-'+[guid]::NewGuid().ToString('N'));New-PASeasyVaultDirectory $fixture
        $settings=@{PackagesRoot=(Join-Path $fixture 'packages');AutomationRoot=(Join-Path $fixture 'automation');KeysDir=(Join-Path $fixture 'keys');DataDrive='C:'}
        foreach($path in @($settings.PackagesRoot,$settings.AutomationRoot,$settings.KeysDir)){New-PASeasyVaultDirectory $path}
        $zip=Join-Path $settings.PackagesRoot 'PACLI-Rls.zip'
        New-VaultZip $zip @(@{Name='Pacli.exe';Body='safe'})
        Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($zip)).SetAccessControl((New-PASeasyVaultSecurity $false))}
        $null=Expand-PASeasyVaultMedia $settings 'PACLI'
        $destination=Join-Path $settings.PackagesRoot 'PACLI'
        $log=Join-Path $destination 'setup.log'
        [IO.File]::WriteAllText($log,'Actual synthetic vendor log bytes remain unchanged')
        $acl=Get-Acl $log;$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
        Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($log)).SetAccessControl($acl)}
        (Get-Acl $log).AreAccessRulesProtected|Should -BeFalse
        (Get-Acl $log).GetOwner([Security.Principal.SecurityIdentifier]).Value|Should -Be 'S-1-5-18'
    }
    AfterEach {if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
    It 'verifies existing media and workspace without changing the inherited SYSTEM log' {
        $beforeHash=(Get-FileHash $log).Hash;$beforeAcl=(Get-Acl $log).Sddl
        Test-PASeasyVaultExtractedMedia $settings 'PACLI'|Should -BeTrue
        Expand-PASeasyVaultMedia $settings 'PACLI'|Should -BeFalse
        # Restrict only the test's path enumeration to this fixture; actual NTFS admission is unmocked.
        Mock Get-PASeasyVaultWorkspacePaths {@($settings.PackagesRoot,$settings.AutomationRoot,$settings.KeysDir)}
        Write-PASeasyVaultOwnedFile (Join-Path $settings.AutomationRoot 'management-policy.json') ([Text.Encoding]::UTF8.GetBytes('{"schemaVersion":1,"Role":"Primary"}')) -CreateNew
        Protect-PASeasyVaultWorkspace $settings -ValidateOnly
        (& (Join-Path $common 'Verify-Paths.ps1') -Settings $settings).Passed|Should -BeTrue
        Protect-PASeasyVaultWorkspace $settings
        (Get-FileHash $log).Hash|Should -BeExactly $beforeHash
        (Get-Acl $log).Sddl|Should -BeExactly $beforeAcl
    }
    It 'refuses extra readers, writers, orphan owners and reparse entries' -TestCases @(
        @{Kind='reader'},@{Kind='writer'},@{Kind='owner'},@{Kind='junction'}
    ) {param($Kind)
        if($Kind -eq 'junction'){
            $outside=Join-Path $fixture 'outside';New-PASeasyVaultDirectory $outside
            $link=Join-Path $destination 'link';New-Item -ItemType Junction -Path $link -Target $outside|Out-Null
            try{{Test-PASeasyVaultExtractedMedia $settings 'PACLI'}|Should -Throw '*reparse*'}finally{[IO.Directory]::Delete($link)}
        } else {
            $acl=Get-Acl $log
            switch($Kind){
                'reader'{$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'Read','Allow'))}
                'writer'{$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'Write','Allow'))}
                'owner'{$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-94-1'))}
            }
            Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($log)).SetAccessControl($acl)}
            $before=(Get-Acl $log).Sddl
            {Test-PASeasyVaultExtractedMedia $settings 'PACLI'}|Should -Throw
            {Expand-PASeasyVaultMedia $settings 'PACLI'}|Should -Throw
            Mock Get-PASeasyVaultWorkspacePaths {@($settings.PackagesRoot,$settings.AutomationRoot,$settings.KeysDir)}
            {Protect-PASeasyVaultWorkspace $settings -ValidateOnly}|Should -Throw
            (Get-Acl $log).Sddl|Should -BeExactly $before
        }
    }
    It 'rejects inherit-only outsider rules before future vendor files can inherit them' {
        $directory=Join-Path $destination 'future-logs';New-PASeasyVaultDirectory $directory
        $acl=Get-Acl $directory
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'Read','ContainerInherit,ObjectInherit','InheritOnly','Allow'))
        ([IO.DirectoryInfo]::new($directory)).SetAccessControl($acl)
        {Test-PASeasyVaultExtractedMedia $settings 'PACLI'}|Should -Throw '*unexpected principal*'
        Test-Path (Join-Path $directory 'future.log')|Should -BeFalse
    }
    It 'still requires protected roots, ZIPs, markers and every pinned source file' -TestCases @(
        @{Kind='root'},@{Kind='archive'},@{Kind='marker'},@{Kind='pinned'}
    ) {param($Kind)
        $target=switch($Kind){'root'{$destination}'archive'{$zip}'marker'{Join-Path $destination '.paeasy-extracted.json'}'pinned'{Join-Path $destination 'Pacli.exe'}}
        $acl=Get-Acl $target;$acl.SetAccessRuleProtection($false,$false)
        if((Get-Item $target).PSIsContainer){([IO.DirectoryInfo]::new($target)).SetAccessControl($acl)}else{([IO.FileInfo]::new($target)).SetAccessControl($acl)}
        (Get-Acl $target).AreAccessRulesProtected|Should -BeFalse
        {Test-PASeasyVaultExtractedMedia $settings 'PACLI'}|Should -Throw '*protected*'
        Mock Get-PASeasyVaultWorkspacePaths {@($settings.PackagesRoot,$settings.AutomationRoot,$settings.KeysDir)}
        {Protect-PASeasyVaultWorkspace $settings -ValidateOnly}|Should -Throw '*protected*'
    }
}
