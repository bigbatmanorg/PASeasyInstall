# Target-only component boundary. Validate ownership before repairing any DACL.
. (Join-Path $PSScriptRoot 'Ownership.ps1')
function Protect-PASeasyComponentWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Settings,
        [string]$BaseRoot = 'C:\ProgramData\PASeasyInstall', [switch]$ValidateOnly, [switch]$PrepareTransfer)
    if ($ValidateOnly -and $PrepareTransfer) { throw 'PrepareTransfer and ValidateOnly are mutually exclusive' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', $identity.User.Value)
    $managementSid = ''
    if ($Settings.ContainsKey('ManagementUser') -and $Settings.ManagementUser) {
        $managementName = [string]$Settings.ManagementUser
        if ($managementName.StartsWith('.\')) { $managementName = $env:COMPUTERNAME + $managementName.Substring(1) }
        elseif (-not $managementName.Contains('\') -and
            -not $managementName.Contains('@')) { $managementName = $env:COMPUTERNAME + '\' + $managementName }
        $managementSid = ([Security.Principal.NTAccount]::new($managementName)).Translate([Security.Principal.SecurityIdentifier]).Value
        $trusted += @($managementSid)
    }
    function New-WorkspaceSecurity([bool]$Directory, [bool]$StableOwner) {
        if ($Directory) {
            $acl = [Security.AccessControl.DirectorySecurity]::new()
            $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        } else {
            $acl = [Security.AccessControl.FileSecurity]::new()
            $inherit = [Security.AccessControl.InheritanceFlags]::None
        }
        $acl.SetAccessRuleProtection($true, $false)
        if ($StableOwner) { $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')) }
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid), 'FullControl', $inherit, 'None', 'Allow'))
        }
        return $acl
    }
    $base = [IO.Path]::GetFullPath($BaseRoot).TrimEnd('\')
    $id = [string]$Settings.Id
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$' -or $id.EndsWith('.')) { throw 'Unsafe component workspace ID' }
    $root = [IO.Path]::GetFullPath([string]$Settings.StageRoot).TrimEnd('\')
    $media = [IO.Path]::GetFullPath([string]$Settings.MediaTarget)
    if ($root -ine (Join-Path $base ('components\' + $id)) -or
        $media -ine (Join-Path $base ('media\' + $id + '\installer.zip'))) { throw 'Component workspace is outside its owned boundary' }
    if ([string]$Settings.MediaSHA256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Component media SHA256 is required' }
    function Assert-WorkspaceEntry([string]$Path) {
        $entry = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Workspace reparse entry rejected: $Path" }
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin $trusted) { throw "Workspace owner is untrusted: $Path" }
        return $entry
    }
    # Ancestors are inspected only, never have their ACLs changed.
    foreach ($leaf in @($root, $media)) {
        $ancestor = $leaf
        while ($ancestor) {
            if (Test-Path -LiteralPath $ancestor) { $null = Assert-WorkspaceEntry $ancestor }
            $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        }
    }
    if (-not $PrepareTransfer -and -not(Test-Path -LiteralPath $media -PathType Leaf)) { throw 'Staged component media is missing' }
    if ((Test-Path -LiteralPath $media) -and
        -not(Test-Path -LiteralPath $media -PathType Leaf)) { throw 'Media transfer destination is not a file' }
    $entries = New-Object 'System.Collections.Generic.List[string]'
    foreach ($boundary in @($root, (Split-Path -Parent $media))) {
        if (Test-Path -LiteralPath $boundary) {
            $queue = New-Object 'System.Collections.Generic.Queue[string]'
            $queue.Enqueue($boundary)
            while ($queue.Count) {
                $path = $queue.Dequeue()
                $item = Assert-WorkspaceEntry $path
                $entries.Add($path)
                if ($item.PSIsContainer) { foreach ($child in Get-ChildItem -LiteralPath $path -Force) { $queue.Enqueue($child.FullName) } }
            }
        }
    }
    # Check every existing entry before changing any app-owned ACL, including the media file.
    foreach ($path in @($base, (Join-Path $base 'components'), (Join-Path $base 'media'), $root, (Split-Path -Parent $media))) {
        if (-not(Test-Path -LiteralPath $path)) {
            if ($ValidateOnly) { throw 'Component workspace directory missing' }
            Invoke-PASeasyWithRestorePrivilege { [IO.Directory]::CreateDirectory($path, (New-WorkspaceSecurity $true $true)) | Out-Null }
        }
        $null = Assert-WorkspaceEntry $path
        if (-not $ValidateOnly) {
            $owner = (Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value
            $normalize = ($owner -eq $identity.User.Value -or ($managementSid -and $owner -eq $managementSid))
            if ($normalize) { Invoke-PASeasyWithRestorePrivilege { ([IO.DirectoryInfo]::new($path)).SetAccessControl((New-WorkspaceSecurity $true $true)) } }
            else { ([IO.DirectoryInfo]::new($path)).SetAccessControl((New-WorkspaceSecurity $true $false)) }
        }
        if (-not $entries.Contains($path)) { $entries.Add($path) }
    }
    foreach ($path in $entries) {
        $item = Assert-WorkspaceEntry $path
        if ($ValidateOnly) {
            $existing = Get-Acl -LiteralPath $path
            $writeMask = [Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
            foreach ($rule in $existing.Access) {
                if ($rule.AccessControlType -eq 'Allow' -and
                    ($rule.FileSystemRights -band $writeMask) -and
                    $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw "Workspace permits an untrusted writer: $path" }
            }
            continue
        }
        $owner = (Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value
        $normalize = ($owner -eq $identity.User.Value -or ($managementSid -and $owner -eq $managementSid))
        $acl = New-WorkspaceSecurity ([bool]$item.PSIsContainer) ([bool]$normalize)
        if ($normalize) { Invoke-PASeasyWithRestorePrivilege { if ($item.PSIsContainer) { ([IO.DirectoryInfo]$item).SetAccessControl($acl) }else { ([IO.FileInfo]$item).SetAccessControl($acl) } } }
        elseif ($item.PSIsContainer) { ([IO.DirectoryInfo]$item).SetAccessControl($acl) }else { ([IO.FileInfo]$item).SetAccessControl($acl) }
    }
    if ($PrepareTransfer -and -not(Test-Path -LiteralPath $media)) {
        # Ownership/DACL are supplied at CreateNew, so interruption never leaves a VA-owned stub.
        Invoke-PASeasyWithRestorePrivilege {
            $stream = [IO.FileStream]::new($media, [IO.FileMode]::CreateNew, [Security.AccessControl.FileSystemRights]::FullControl, [IO.FileShare]::None, 4096, [IO.FileOptions]::None, (New-WorkspaceSecurity $false $true))
            $stream.Dispose()
        }
    }
    if ($PrepareTransfer) { return }
    $null = Assert-WorkspaceEntry $media
    if ((Get-FileHash -LiteralPath $media -Algorithm SHA256).Hash -ine [string]$Settings.MediaSHA256) { throw 'Staged component media SHA256 differs from frozen controller media' }
}
