# Validates the entire archive before writing; extraction is published atomically.
# The destination must be new. Only the attempt-created temporary directory is removed.
function Expand-PASeasyComponentArchive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination,
        [ValidateRange(1,500000)][int]$MaxFiles=50000,
        [ValidateRange(1,1099511627776)][long]$MaxBytes=21474836480,[scriptblock]$Include)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $dest=[IO.Path]::GetFullPath($Destination)
    if(Test-Path -LiteralPath $dest){throw 'Archive destination already exists; reconcile before extraction'}
    $parent=[IO.Path]::GetDirectoryName($dest)
    if(-not $parent -or $dest -eq [IO.Path]::GetPathRoot($dest)){throw 'Archive destination must be a child directory'}
    $ancestor=$parent
    while($ancestor){
        if(Test-Path -LiteralPath $ancestor){
            if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Archive destination has a reparse ancestor'}
        }
        $ancestor=[IO.Path]::GetDirectoryName($ancestor)
    }
    $zip=[IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Source))
    $temp=$null
    try {
        if($zip.Entries.Count -gt $MaxFiles){throw 'Archive file-count limit exceeded'}
        $names=New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([StringComparer]::OrdinalIgnoreCase)
        $prepared=New-Object System.Collections.ArrayList
        $total=[long]0
        foreach($entry in $zip.Entries){
            $raw=$entry.FullName.Replace('\','/')
            if(-not $raw -or $raw.StartsWith('/') -or $raw.Contains(':')){throw 'Archive contains an absolute or ADS path'}
            $directory=$raw.EndsWith('/');$name=$raw.TrimEnd('/')
            $parts=$name.Split('/')
            foreach($part in $parts){
                if(-not $part -or $part -in @('.','..') -or $part -ne $part.TrimEnd(' ','.') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0){throw 'Archive contains an unsafe Windows path component'}
            }
            $kind=($entry.ExternalAttributes -shr 16) -band 61440
            if($kind -notin @(0,16384,32768)){throw 'Archive links and special files are prohibited'}
            if($names.ContainsKey($name)){throw 'Archive contains duplicate or case-aliased paths'}
            $names.Add($name,$directory)
            if($entry.Length -lt 0 -or $entry.Length -gt ($MaxBytes-$total)){throw 'Archive expanded-size limit exceeded'}
            $total+=$entry.Length
            [void]$prepared.Add(@{Entry=$entry;Name=$name;Directory=$directory})
        }
        foreach($item in $prepared){
            $prefix=$item.Name
            while($prefix.Contains('/')){
                $prefix=$prefix.Substring(0,$prefix.LastIndexOf('/'))
                if($names.ContainsKey($prefix) -and -not $names[$prefix]){throw 'Archive file shadows a directory'}
            }
        }
        if(-not(Test-Path -LiteralPath $parent)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
        $temp=Join-Path $parent ('.extract-'+[guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($temp)|Out-Null
        $written=[long]0;$buffer=New-Object byte[] 65536
        foreach($item in $prepared){
            if($Include -and -not $item.Directory -and -not (& $Include $item.Entry.Name)){continue}
            $target=[IO.Path]::GetFullPath((Join-Path $temp $item.Name.Replace('/',[IO.Path]::DirectorySeparatorChar)))
            if(-not $target.StartsWith(($temp+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)){throw 'Archive target escaped staging'}
            if($item.Directory){[IO.Directory]::CreateDirectory($target)|Out-Null;continue}
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null
            $input=$item.Entry.Open();$output=$null
            try {
                $output=[IO.File]::Open($target,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                $length=[long]0
                while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0){
                    if($read -gt ($MaxBytes-$written)){throw 'Archive actual expanded-size limit exceeded'}
                    $written+=$read;$length+=$read;$output.Write($buffer,0,$read)
                }
                if($length -ne $item.Entry.Length){throw 'Archive entry size mismatch'}
            } finally {if($output){$output.Dispose()};$input.Dispose()}
        }
        [IO.Directory]::Move($temp,$dest);$temp=$null
        return $dest
    } finally {
        $zip.Dispose()
        if($temp -and (Test-Path -LiteralPath $temp)){Remove-Item -LiteralPath $temp -Recurse -Force}
    }
}
