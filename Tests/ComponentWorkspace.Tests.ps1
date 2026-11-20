BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall/Recipes/WindowsComponent/Workspace.ps1')
}
Describe 'Component workspace ownership and content boundary' {
    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $media = Join-Path $base 'media\pvwa\installer.zip'
        New-Item -ItemType Directory -Path (Split-Path -Parent $media) -Force | Out-Null
        [IO.File]::WriteAllText($media, 'fixture')
        $settings = @{
            Id = 'pvwa'
            StageRoot = (Join-Path $base 'components\pvwa')
            MediaTarget = $media
            MediaSHA256 = (Get-FileHash $media).Hash
        }
    }
    It 'protects existing payload and media and remains repeatable without changing outside ACLs' {
        $payload = Join-Path $settings.StageRoot 'payload'
        New-Item -ItemType Directory $payload -Force | Out-Null
        $scriptFile = Join-Path $payload 'vendor.ps1'
        Set-Content $scriptFile 'fixture'
        $acl = Get-Acl $scriptFile
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'), 'FullControl', 'Allow'))
        Set-Acl $scriptFile $acl
        $outside = (Get-Acl (Split-Path -Parent $base)).Sddl
        foreach ($pass in 1..2) { Protect-PASeasyComponentWorkspace -Settings $settings -BaseRoot $base }
        Protect-PASeasyComponentWorkspace -Settings $settings -BaseRoot $base -ValidateOnly
        foreach ($file in @($scriptFile, $media)) {
            (Get-Acl $file).AreAccessRulesProtected | Should -BeTrue
            @((Get-Acl $file).Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-545' }).Count |
                Should -Be 0
        }
        (Get-Acl (Split-Path -Parent $base)).Sddl | Should -BeExactly $outside
    }
    It 'refuses untrusted writer in read-only validation without repairing it' {
        Protect-PASeasyComponentWorkspace $settings -BaseRoot $base
        $acl = Get-Acl $media
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'), 'FullControl', 'Allow'))
        Set-Acl $media $acl
        $before = (Get-Acl $media).Sddl
        { Protect-PASeasyComponentWorkspace $settings -BaseRoot $base -ValidateOnly } | Should -Throw '*writer*'
        (Get-Acl $media).Sddl | Should -BeExactly $before
    }
    It 'requires frozen media hash and rejects corruption' {
        $settings.MediaSHA256 = ''
        { Protect-PASeasyComponentWorkspace $settings -BaseRoot $base } | Should -Throw '*SHA256*'
        $settings.MediaSHA256 = ('0' * 64)
        { Protect-PASeasyComponentWorkspace $settings -BaseRoot $base } | Should -Throw '*differs*'
    }
    It 'rejects mismatched boundaries and unsafe IDs' {
        $settings.StageRoot = Join-Path $base 'unrelated'
        { Protect-PASeasyComponentWorkspace $settings -BaseRoot $base } | Should -Throw '*boundary*'
        $settings.Id = '../escape'
        { Protect-PASeasyComponentWorkspace $settings -BaseRoot $base } | Should -Throw '*ID*'
    }
    It 'rejects an untrusted existing file owner without adopting it' {
        $acl = Get-Acl $media
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'))
        Set-Acl $media $acl
        $before = (Get-Acl $media).Sddl
        { Protect-PASeasyComponentWorkspace $settings -BaseRoot $base } | Should -Throw '*owner*'
        (Get-Acl $media).Sddl | Should -BeExactly $before
    }
    It 'rejects a reparse subtree before changing ACLs' {
        New-Item -ItemType Directory $settings.StageRoot -Force | Out-Null
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory $outside -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $settings.StageRoot 'payload') -Target $outside | Out-Null
        try {
            { Protect-PASeasyComponentWorkspace $settings -BaseRoot $base } |
                Should -Throw '*reparse*'
        } finally { [IO.Directory]::Delete((Join-Path $settings.StageRoot 'payload')) }
    }
}

Describe 'Component media preparation precedes all content reads and upload' {
    BeforeEach {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $settings = @{
            Id = 'cpm'
            StageRoot = (Join-Path $base 'components\cpm')
            MediaTarget = (Join-Path $base 'media\cpm\installer.zip')
            MediaSHA256 = ('a' * 64)
        }
    }
    It 'creates and protects owned boundaries without hashing or requiring media' {
        Mock Get-FileHash { throw 'Hash must not run during preparation' }
        Protect-PASeasyComponentWorkspace -Settings $settings -BaseRoot $base -PrepareTransfer
        Test-Path $settings.MediaTarget | Should -BeTrue
        (Get-Item $settings.MediaTarget).Length | Should -Be 0
        (Get-Acl $settings.MediaTarget).GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -BeExactly 'S-1-5-32-544'
        (Get-Acl (Split-Path -Parent $settings.MediaTarget)).AreAccessRulesProtected | Should -BeTrue
        Should -Invoke Get-FileHash -Times 0
    }
    It 'rejects an untrusted destination owner before hashing or modifying the file' {
        New-Item -ItemType Directory (Split-Path -Parent $settings.MediaTarget) -Force | Out-Null
        Set-Content $settings.MediaTarget 'fixture'
        $acl = Get-Acl $settings.MediaTarget
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'))
        Set-Acl $settings.MediaTarget $acl
        $before = (Get-Acl $settings.MediaTarget).Sddl
        Mock Get-FileHash { throw 'Hash must not run during preparation' }
        { Protect-PASeasyComponentWorkspace -Settings $settings -BaseRoot $base -PrepareTransfer } | Should -Throw '*owner*'
        (Get-Acl $settings.MediaTarget).Sddl | Should -BeExactly $before
        Should -Invoke Get-FileHash -Times 0
    }
    It 'rejects a redirected media directory before creating the destination' {
        New-Item -ItemType Directory (Join-Path $base 'media') -Force | Out-Null
        $outside = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $outside | Out-Null
        $junction = Join-Path $base 'media\cpm'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        try {
            { Protect-PASeasyComponentWorkspace -Settings $settings -BaseRoot $base -PrepareTransfer } | Should -Throw '*reparse*'
            Test-Path (Join-Path $outside 'installer.zip') | Should -BeFalse
        } finally { [IO.Directory]::Delete($junction) }
    }
}

Describe 'Stable workspace ownership across elevated identities' {
    It 'normalizes only the validated current owner and leaves only SYSTEM/Administrators writers' {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $media = Join-Path $base 'media\owner\installer.zip'
        New-Item -ItemType Directory (Split-Path -Parent $media) -Force | Out-Null
        Set-Content $media 'fixture'
        $acl = Get-Acl $media
        $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
        Set-Acl $media $acl
        $settings = @{
            Id = 'owner'
            StageRoot = (Join-Path $base 'components\owner')
            MediaTarget = $media
            MediaSHA256 = (Get-FileHash $media).Hash
        }
        Protect-PASeasyComponentWorkspace $settings -BaseRoot $base
        $after = Get-Acl $media
        $after.GetOwner([Security.Principal.SecurityIdentifier]).Value | Should -BeExactly 'S-1-5-32-544'
        @($after.Access | Where-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18', 'S-1-5-32-544') }).Count |
            Should -Be 0
    }
    It 'does not trust a previous virtual-account SID namespace' -Tag 'RequiresLabController' {
        $base = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $media = Join-Path $base 'media\oldva\installer.zip'
        New-Item -ItemType Directory (Split-Path -Parent $media) -Force | Out-Null
        Set-Content $media 'fixture'
        $settings = @{
            Id = 'oldva'
            StageRoot = (Join-Path $base 'components\oldva')
            MediaTarget = $media
            MediaSHA256 = (Get-FileHash $media).Hash
        }
        Mock Get-Acl {
            $a = [Security.AccessControl.FileSecurity]::new()
            $a.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-94-987654'))
            $a
        } -ParameterFilter { $LiteralPath -eq $media }
        { Protect-PASeasyComponentWorkspace $settings -BaseRoot $base -PrepareTransfer } | Should -Throw '*owner*'
    }
}
