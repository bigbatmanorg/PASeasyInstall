function Get-PASWindowsStagePreparation {
    # Self-contained for PSRP and Windows runtime adversarial tests.
    $body = {
        param([string]$Root, [string]$LockKey = '', [string]$RunId = '', [bool]$Release = $false, [string]$AuthenticatedUser = '')
        # PAEASY_STATIC_OWNERSHIP_HELPER
        $ErrorActionPreference = 'Stop'
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        if (-not([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Remote staging requires an elevated management identity' }
        if ($Root -notmatch '^[A-Za-z]:\\') { throw 'Remote staging root must be an absolute local path' }
        $full = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        if ($full -notmatch '^[A-Za-z]:\\' -or
            $full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\') -or
            $full.Substring(2).Contains(':')) { throw 'Unsafe remote staging root' }
        foreach ($systemPath in @($env:SystemRoot, [Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'))) {
            if ($systemPath -and
                ($full -ieq $systemPath.TrimEnd('\') -or
                $full.StartsWith(($systemPath.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase))) { throw 'Remote staging cannot own an operating system directory' }
        }
        $trusted = @($identity.User.Value, 'S-1-5-18', 'S-1-5-32-544')
        if ($AuthenticatedUser) {
            $account = $AuthenticatedUser
            if ($account.StartsWith('.\')) { $account = $env:COMPUTERNAME + '\' + $account.Substring(2) }
            elseif (-not $account.Contains('\') -and -not $account.Contains('@')) { $account = $env:COMPUTERNAME + '\' + $account }
            $trusted += ([Security.Principal.NTAccount]::new($account)).Translate([Security.Principal.SecurityIdentifier]).Value
        }
        try { $trusted += ([Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller')).Translate([Security.Principal.SecurityIdentifier]).Value }catch {}
        function Assert-StageEntry([string]$Path) {
            if (-not(Test-Path -LiteralPath $Path)) { return }
            if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Remote staging has a reparse entry' }
            if ((Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'Remote staging has an untrusted owner' }
        }
        $cursor = $full
        while ($cursor) {
            Assert-StageEntry $cursor
            $next = Split-Path $cursor -Parent
            if ($next -eq $cursor) { break }
            $cursor = $next
        }
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) { $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')) }
        foreach ($dir in @($full, (Join-Path $full 'locks'), (Join-Path $full 'attempts'))) {
            Assert-StageEntry $dir
            if (-not(Test-Path -LiteralPath $dir)) { Invoke-PASeasyWithRestorePrivilege { [void][IO.Directory]::CreateDirectory($dir, $acl) } }
            Assert-StageEntry $dir
            Invoke-PASeasyWithRestorePrivilege { ([IO.DirectoryInfo]::new($dir)).SetAccessControl($acl) }
        }
        if (-not $LockKey) { return [pscustomobject]@{Message = 'Stage ownership and ACL prepared' } }
        if ($LockKey -notmatch '^[A-Za-z0-9_.-]{1,64}$' -or
            $RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{5,79}$') { throw 'Invalid staging lease identity' }
        $dir = Join-Path (Join-Path $full 'locks') $LockKey
        $ownerPath = Join-Path $dir 'owner.txt'
        Assert-StageEntry $dir
        Assert-StageEntry $ownerPath
        if ($Release) {
            if (Test-Path -LiteralPath $ownerPath) {
                $owner = [IO.File]::ReadAllText($ownerPath).Trim()
                if ($owner -eq $RunId) {
                    if (@(Get-ChildItem $dir -Force | Where-Object { $_.Name -ne 'owner.txt' }).Count) { throw 'Unexpected lease contents; refusing recursive cleanup' }
                    [IO.File]::Delete($ownerPath)
                    [IO.Directory]::Delete($dir)
                    return [pscustomobject]@{Message = 'released' }
                }
                # The lock belongs to another run: it is left alone and its owner is reported.
                return [pscustomobject]@{Message = ('held:' + $owner) }
            }
            return [pscustomobject]@{Message = 'none' }
        }
        if (-not(Test-Path -LiteralPath $dir)) { Invoke-PASeasyWithRestorePrivilege { [void][IO.Directory]::CreateDirectory($dir, $acl) } }
        Assert-StageEntry $dir
        Invoke-PASeasyWithRestorePrivilege { ([IO.DirectoryInfo]::new($dir)).SetAccessControl($acl) }
        try {
            $fileAcl = [Security.AccessControl.FileSecurity]::new()
            $fileAcl.SetAccessRuleProtection($true, $false)
            $fileAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) { $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow')) }
            $stream = Invoke-PASeasyWithRestorePrivilege { [IO.FileStream]::new($ownerPath, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::None, $fileAcl) }
            try {
                $bytes = [Text.Encoding]::ASCII.GetBytes($RunId)
                $stream.Write($bytes, 0, $bytes.Length)
            } finally { $stream.Dispose() }
            $message = 'acquired'
        } catch [IO.IOException] {
            if (-not(Test-Path -LiteralPath $ownerPath)) { throw }
            Assert-StageEntry $ownerPath
            $owner = [IO.File]::ReadAllText($ownerPath).Trim()
            $message = if ($owner -eq $RunId) { 'acquired' }else { 'locked:' + $owner }
        }
        [pscustomobject]@{Message = $message }
    }
    $moduleRoot = Split-Path (Split-Path $script:PASEngineRoot -Parent) -Parent
    $helper = Join-Path $moduleRoot 'Recipes/WindowsComponent/Ownership.ps1'
    return [scriptblock]::Create($body.ToString().Replace('# PAEASY_STATIC_OWNERSHIP_HELPER', [IO.File]::ReadAllText($helper)))
}
function Initialize-PASWindowsStageRoot {
    param([hashtable]$Target, [hashtable]$Credentials)
    Assert-PASDetachedSupported $Target
    $session = Get-PASConnection $Target $Credentials
    $root = [string](Get-PASValue $Target 'StageRoot' 'C:\ProgramData\PAExec')
    $reference = [string](Get-PASValue $Target 'CredentialRef' '')
    $user = if ($reference -and $Credentials.ContainsKey($reference)) { [string]$Credentials[$reference].UserName }else { '' }
    [void](Invoke-Command -Session $session -ScriptBlock (Get-PASWindowsStagePreparation) -ArgumentList $root, '', '', $false, $user -ErrorAction Stop)
}
function Get-PASWindowsFilePreparation {
    $body = {
        param([string]$Destination, [string]$ManagementUser = '', [bool]$ValidateOnly = $false, [bool]$CreateFile = $true)
        # PAEASY_STATIC_OWNERSHIP_HELPER
        $ErrorActionPreference = 'Stop'
        if (-not([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Upload preparation requires an elevated management identity' }
        if ($Destination -notmatch '^[A-Za-z]:\\' -or
            $Destination.Substring(2).Contains(':')) { throw 'Upload requires an absolute local non-ADS file path' }
        $path = [IO.Path]::GetFullPath($Destination)
        $parent = [IO.Path]::GetDirectoryName($path)
        if (-not $parent) { throw 'Upload destination has no parent' }
        foreach ($systemPath in @($env:SystemRoot, [Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'))) {
            if ($systemPath -and
                ($path -ieq $systemPath -or
                $path.StartsWith(($systemPath.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase))) { throw 'Media upload cannot replace operating-system or installed-program files' }
        }
        $trusted = @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        try { $trusted += ([Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller')).Translate([Security.Principal.SecurityIdentifier]).Value }catch {}
        if ($ManagementUser) {
            $account = $ManagementUser
            if ($account.StartsWith('.\')) { $account = $env:COMPUTERNAME + '\' + $account.Substring(2) }
            elseif (-not $account.Contains('\') -and -not $account.Contains('@')) { $account = $env:COMPUTERNAME + '\' + $account }
            $trusted += ([Security.Principal.NTAccount]::new($account)).Translate([Security.Principal.SecurityIdentifier]).Value
        }
        $cursor = $path
        while ($cursor) {
            if (Test-Path -LiteralPath $cursor) {
                if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Upload destination has a reparse ancestor' }
                if ((Get-Acl -LiteralPath $cursor).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'Upload destination has an untrusted owner' }
            }
            $next = Split-Path $cursor -Parent
            if ($next -eq $cursor) { break }
            $cursor = $next
        }
        if ($ValidateOnly) {
            if (-not(Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Previously uploaded file is missing' }
            if ((Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18', 'S-1-5-32-544')) { throw 'Previously uploaded file lacks stable ownership' }
            foreach ($rule in (Get-Acl -LiteralPath $path).Access) {
                if ($rule.AccessControlType -eq 'Allow' -and
                    $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18', 'S-1-5-32-544')) { throw 'Uploaded media permits an untrusted reader or writer' }
            }
            return [pscustomobject]@{Path = $path; ApprovedRoot = $parent; Validated = $true }
        }
        $directoryAcl = [Security.AccessControl.DirectorySecurity]::new()
        $directoryAcl.SetAccessRuleProtection($true, $false)
        $directoryAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) { $directoryAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')) }
        if ($parent.TrimEnd('\') -ne [IO.Path]::GetPathRoot($parent).TrimEnd('\')) {
            Invoke-PASeasyWithRestorePrivilege {
                if (-not(Test-Path -LiteralPath $parent)) { [void][IO.Directory]::CreateDirectory($parent, $directoryAcl) }
                ([IO.DirectoryInfo]::new($parent)).SetAccessControl($directoryAcl)
            }
        }
        $fileAcl = [Security.AccessControl.FileSecurity]::new()
        $fileAcl.SetAccessRuleProtection($true, $false)
        $fileAcl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) { $fileAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', 'Allow')) }
        if ($CreateFile) {
            Invoke-PASeasyWithRestorePrivilege {
                if (-not(Test-Path -LiteralPath $path)) {
                    $stream = [IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, $fileAcl)
                    $stream.Dispose()
                } else { ([IO.FileInfo]::new($path)).SetAccessControl($fileAcl) }
            }
        }
        $owner = if (Test-Path -LiteralPath $path) { (Get-Acl $path).GetOwner([Security.Principal.SecurityIdentifier]).Value }else { '' }
        [pscustomobject]@{Path = $path; ApprovedRoot = $parent; OwnerSID = $owner }
    }
    $moduleRoot = Split-Path (Split-Path $script:PASEngineRoot -Parent) -Parent
    $helper = Join-Path $moduleRoot 'Recipes/WindowsComponent/Ownership.ps1'
    return [scriptblock]::Create($body.ToString().Replace('# PAEASY_STATIC_OWNERSHIP_HELPER', [IO.File]::ReadAllText($helper)))
}
