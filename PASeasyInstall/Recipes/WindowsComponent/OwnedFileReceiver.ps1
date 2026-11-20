# PSRP byte[] receiver. The caller prepares a stable private file under its validated app boundary.
# Opens the existing file only; never deletes/recreates it or leaves a stream between chunks.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$ApprovedRoot,
    [ValidateRange(-1, 21474836480)][long]$ExpectedLength = -1,
    [ValidateRange(1, 21474836480)][long]$MaxBytes = 21474836480,
    [ValidateRange(1, 65536)][int]$MaxChunkBytes = 65536, [string]$ManagementUser = '',
    [ValidateRange(0, 21474836480)][long]$StartOffset = 0,
    [ValidateRange(-1, 21474836480)][long]$ExpectedPartialLength = -1, [bool]$Finalize = $true,
    [Parameter(ValueFromPipeline = $true)][object]$Packet)
begin {
    $ErrorActionPreference = 'Stop'
    if ($Destination -notmatch '^[A-Za-z]:\\' -or
        $ApprovedRoot -notmatch '^[A-Za-z]:\\' -or
        $Destination.Substring(2).Contains(':') -or
        $ApprovedRoot.Substring(2).Contains(':')) { throw 'Receiver requires local absolute non-ADS paths' }
    $path = [IO.Path]::GetFullPath($Destination)
    $boundary = [IO.Path]::GetFullPath($ApprovedRoot).TrimEnd('\')
    $windows = [Environment]::GetFolderPath('Windows').TrimEnd('\')
    $programData = [Environment]::GetFolderPath('CommonApplicationData').TrimEnd('\')
    if ($boundary -eq [IO.Path]::GetPathRoot($boundary).TrimEnd('\') -or
        $boundary -ieq $programData -or
        $boundary -ieq $windows -or
        $boundary.StartsWith(($windows + '\'), [StringComparison]::OrdinalIgnoreCase) -or
        -not $path.StartsWith(($boundary + '\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Receiver destination is outside a specific app boundary' }
    if ($ExpectedLength -gt $MaxBytes) { throw 'Receiver expected size exceeds its bound' }
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    if ($ManagementUser) {
        $account = $ManagementUser
        if ($account.StartsWith('.\')) { $account = $env:COMPUTERNAME + $account.Substring(1) }
        elseif (-not $account.Contains('\') -and -not $account.Contains('@')) { $account = $env:COMPUTERNAME + '\' + $account }
        $trusted += ([Security.Principal.NTAccount]::new($account)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    if (-not(Test-Path -LiteralPath $path -PathType Leaf) -or
        -not(Test-Path -LiteralPath $boundary -PathType Container)) { throw 'Receiver requires its precreated stable file and app directory' }
    $ancestor = $path
    while ($ancestor) {
        $entry = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Receiver path has a reparse entry' }
        $acl = Get-Acl -LiteralPath $ancestor -ErrorAction Stop
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin $trusted) { throw 'Receiver path has an untrusted owner' }
        if ($ancestor -ieq $path -and
            $owner -notin @('S-1-5-18', 'S-1-5-32-544')) { throw 'Receiver file does not have a stable privileged owner' }
        if ($ancestor -ieq $boundary -or $ancestor.StartsWith(($boundary + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            $writeMask = [Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
            foreach ($rule in $acl.Access) {
                $who = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
                if ($rule.AccessControlType -eq 'Allow' -and
                    $who -notin @('S-1-5-18', 'S-1-5-32-544') -and
                    ($ancestor -ieq $path -or
                    ($rule.FileSystemRights -band $writeMask))) { throw 'Receiver app path permits an untrusted reader or writer' }
            }
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    $length = (Get-Item -LiteralPath $path).Length
    if (($ExpectedPartialLength -ge 0 -and
            $length -ne $ExpectedPartialLength) -or
        ($StartOffset -gt 0 -and
        $length -ne $StartOffset)) { throw 'Receiver partial length does not match the approved offset' }
    if ($StartOffset -gt $MaxBytes -or
        ($ExpectedLength -ge 0 -and
        $StartOffset -gt $ExpectedLength)) { throw 'Receiver offset exceeds its bound' }
    $total = [long]0
    $position = $StartOffset
    $chunks = [long]0
    $initialized = $false
}
process {
    if ($PSBoundParameters.ContainsKey('Packet')) {
        $chunk = $Packet
        if ($chunk -isnot [byte[]] -or
            $chunk.Length -lt 1 -or
            $chunk.Length -gt $MaxChunkBytes) { throw 'Receiver rejected an invalid byte chunk' }
        if ($chunks -ge 1048576 -or
            $chunk.Length -gt ($MaxBytes - $position) -or
            ($ExpectedLength -ge 0 -and
            $chunk.Length -gt ($ExpectedLength - $position))) { throw 'Receiver upload size/count bound exceeded' }
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            if (-not $initialized -and
                $StartOffset -eq 0) { $stream.SetLength(0) }elseif ($stream.Length -ne $position) { throw 'Receiver partial length changed during upload' }
            $initialized = $true
            $stream.Position = $position
            $stream.Write($chunk, 0, $chunk.Length)
            $total += $chunk.Length
            $position += $chunk.Length
            $chunks++
        } finally { $stream.Dispose() }
    }
}
end {
    if ($Finalize -and $ExpectedLength -ge 0 -and $position -ne $ExpectedLength) { throw 'Receiver upload ended before its expected length' }
    if (-not $initialized -and -not $Finalize) { throw 'Receiver batch made no progress' }
    if (-not $initialized -and $StartOffset -eq 0) {
        $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.SetLength(0) }finally { $stream.Dispose() }
    }
    [pscustomobject]@{
        Bytes = $total
        StartOffset = $StartOffset
        NextOffset = $position
        Finalized = $Finalize
        Chunks = $chunks
        Sha256 = $(if ($Finalize) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash }else { $null })
        OwnerSID = (Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value
    }
}
