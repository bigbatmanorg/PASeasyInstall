# Inlined with the reviewed Ownership.ps1 helper. No external module or orphan-VA adoption.
function Get-PASeasyVaultCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    if($Path -notmatch '^[A-Za-z]:\\' -or $Path.Contains('/') -or $Path.Substring(2).Contains(':')){throw 'Vault workspace requires a local absolute Windows path'}
    foreach($part in $Path.Substring(3).Split('\')){if(-not $part -or $part -in @('.','..') -or $part -ne $part.TrimEnd(' ','.') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0){throw 'Unsafe Vault workspace path component'}}
    [IO.Path]::GetFullPath($Path).TrimEnd('\')
}
function Get-PASeasyVaultWorkspacePaths {
    param([hashtable]$Settings)
    if([string]$Settings.DataDrive -notmatch '^[A-Za-z]:\\?$'){throw 'Vault DataDrive must be a local drive'}
    $paths=@($Settings.PackagesRoot,$Settings.AutomationRoot,$Settings.KeysDir,(Join-Path $Settings.AutomationRoot 'PAKeyGen'),(Join-Path $Settings.AutomationRoot 'Templates'),(Join-Path $Settings.AutomationRoot 'Prerequisites'),(Join-Path $Settings.DataDrive 'PrivateArk\StagingArea'))
    foreach($path in $paths){
        $full=Get-PASeasyVaultCanonicalPath ([string]$path)
        $relative=$full.Substring(3)
        if($relative -match '^(?i:Windows|Program Files|Program Files \(x86\))(\\|$)' -or $relative -ieq 'ProgramData' -or $relative -ieq 'Users'){throw 'Vault workspace cannot adopt an OS or global directory'}
        $full
    }
}
function Assert-PASeasyVaultEntry {
    param([Parameter(Mandatory)][string]$Path,[switch]$Directory,[switch]$Ancestor,[switch]$Protected,[switch]$AllowInherited)
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Vault workspace reparse entry rejected'}
    if($Directory -and -not $item.PSIsContainer){throw 'Vault workspace requires a directory'}
    $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop
    $stable=@('S-1-5-18','S-1-5-32-544')
    $owners=$stable;if($Ancestor){$owners+=@('S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')}
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $owners){throw 'Vault workspace owner is not stable and trusted; explicit reconciliation required'}
    $mask=[Security.AccessControl.FileSystemRights]'Write,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'
    if($Ancestor){$mask=[Security.AccessControl.FileSystemRights]'WriteData,AppendData,Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership';if($Path -eq [IO.Path]::GetPathRoot($Path)){$mask=[Security.AccessControl.FileSystemRights]'Delete,DeleteSubdirectoriesAndFiles,ChangePermissions,TakeOwnership'}}
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        $inheritOnly=($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0
        if(-not $inheritOnly -and $rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $mask) -and $rule.IdentityReference.Value -notin $owners){throw 'Vault workspace permits an untrusted writer or deletion'}
        # Even inherit-only readers/writers must not be planted for future vendor children.
        if($Protected -and $rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $stable){throw 'Vault workspace ACL contains an unexpected principal'}
    }
    if($Protected -and -not $AllowInherited -and -not $acl.AreAccessRulesProtected){throw 'Vault workspace ACL inheritance is not protected'}
    $item
}
function Assert-PASeasyVaultAncestors {
    param([string]$Path)
    $current=[IO.Path]::GetDirectoryName($Path)
    while($current){if(Test-Path -LiteralPath $current){$null=Assert-PASeasyVaultEntry $current -Directory -Ancestor};$current=[IO.Path]::GetDirectoryName($current)}
}
function Assert-PASeasyVaultTree {
    param([string]$Path,[switch]$Protected,[switch]$AllowInheritedDescendants)
    Assert-PASeasyVaultAncestors $Path
    $queue=New-Object 'System.Collections.Generic.Queue[string]';$queue.Enqueue($Path)
    while($queue.Count){$next=$queue.Dequeue();$item=Assert-PASeasyVaultEntry $next -Protected:$Protected -AllowInherited:($AllowInheritedDescendants -and $next -ine $Path);if($item.PSIsContainer){foreach($child in Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop){$queue.Enqueue($child.FullName)}}}
}
function New-PASeasyVaultSecurity {
    param([bool]$Directory,[string]$Owner='S-1-5-32-544')
    if($Directory){$acl=New-Object Security.AccessControl.DirectorySecurity;$inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{$acl=New-Object Security.AccessControl.FileSecurity;$inherit=[Security.AccessControl.InheritanceFlags]::None}
    $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]::new($Owner))
    foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl',$inherit,'None','Allow'))}
    $acl
}
function New-PASeasyVaultDirectory {
    param([string]$Path)
    $null=Get-PASeasyVaultCanonicalPath $Path
    Assert-PASeasyVaultAncestors $Path
    if(Test-Path -LiteralPath $Path){$null=Assert-PASeasyVaultEntry $Path -Directory;return}
    $parent=[IO.Path]::GetDirectoryName($Path)
    if(-not(Test-Path -LiteralPath $parent)){New-PASeasyVaultDirectory $parent}
    Invoke-PASeasyWithRestorePrivilege {[IO.Directory]::CreateDirectory($Path,(New-PASeasyVaultSecurity $true))|Out-Null}
    $null=Assert-PASeasyVaultEntry $Path -Directory -Protected
}
function Write-PASeasyVaultOwnedFile {
    param([string]$Path,[byte[]]$Bytes,[switch]$CreateNew)
    Assert-PASeasyVaultAncestors $Path
    $exists=Test-Path -LiteralPath $Path
    if($exists){$item=Assert-PASeasyVaultEntry $Path -Protected;if($item.PSIsContainer -or $CreateNew){throw 'Vault workspace file destination already exists'}}
    $stream=$null
    try{
        if($exists){$stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None);$stream.SetLength(0)}
        else{$stream=Invoke-PASeasyWithRestorePrivilege {[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::FullControl,[IO.FileShare]::None,65536,[IO.FileOptions]::None,(New-PASeasyVaultSecurity $false))}}
        $stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)
    }finally{if($stream){$stream.Dispose()}}
    $null=Assert-PASeasyVaultEntry $Path -Protected
}
function Protect-PASeasyVaultWorkspace {
    param([hashtable]$Settings,[switch]$ValidateOnly)
    $paths=@(Get-PASeasyVaultWorkspacePaths $Settings)
    # Roots remain protected; inherited descendants must still be exclusively private SYS/BA.
    # Admit ALL existing trees and published media before any root creation/ACL replacement.
    foreach($path in $paths){Assert-PASeasyVaultAncestors $path;if(Test-Path -LiteralPath $path){$null=Assert-PASeasyVaultEntry $path -Directory -Protected;Assert-PASeasyVaultTree $path -Protected -AllowInheritedDescendants}elseif($ValidateOnly){throw 'Vault workspace directory missing'}}
    foreach($component in @('Server','Disaster Recovery','PACLI')){
        $marker=Join-Path (Join-Path $Settings.PackagesRoot $component) '.paeasy-extracted.json'
        if(Test-Path -LiteralPath $marker){$null=Test-PASeasyVaultExtractedMedia $Settings $component}
    }
    if($ValidateOnly){return}
    foreach($path in $paths){New-PASeasyVaultDirectory $path}
    # Do not rewrite native vendor-log/key ACLs. Only configured roots receive root policy.
    foreach($path in $paths){
        $item=Assert-PASeasyVaultEntry $path -Directory -Protected
        $acl=New-PASeasyVaultSecurity $true ((Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value)
        Invoke-PASeasyWithRestorePrivilege {([IO.DirectoryInfo]$item).SetAccessControl($acl)}
    }
}
function Get-PASeasyVaultArchiveName {
    param([string]$Component)
    switch -Exact ($Component){'Server'{'Server-Rls.zip'}'Disaster Recovery'{'Disaster Recovery-Rls.zip'}'PACLI'{'PACLI-Rls.zip'}default{throw 'Unknown Vault media component'}}
}
function Test-PASeasyVaultExtractedMedia {
    param([hashtable]$Settings,[string]$Component)
    $zip=Join-Path $Settings.PackagesRoot (Get-PASeasyVaultArchiveName $Component);$dest=Join-Path $Settings.PackagesRoot $Component
    Assert-PASeasyVaultTree $dest -Protected -AllowInheritedDescendants
    $null=Assert-PASeasyVaultEntry $zip -Protected
    $marker=Join-Path $dest '.paeasy-extracted.json';$null=Assert-PASeasyVaultEntry $marker -Protected
    if((Get-Item -LiteralPath $marker).Length -gt 33554432){throw 'Vault extraction marker exceeds limit'}
    $record=Get-Content -LiteralPath $marker -Raw -Encoding UTF8|ConvertFrom-Json
    if($record.schemaVersion -ne 1 -or $record.component -cne $Component -or $record.archiveSHA256 -cne (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash){throw 'Vault extraction marker does not match staged archive'}
    if(-not $record.files -or @($record.files).Count -gt 50000){throw 'Vault extraction marker file list invalid'}
    foreach($file in $record.files){
        $path=Get-PASeasyVaultCanonicalPath (Join-Path $dest ([string]$file.path))
        if(-not $path.StartsWith($dest+'\',[StringComparison]::OrdinalIgnoreCase) -or [string]$file.sha256 -notmatch '^[A-F0-9]{64}$'){throw 'Vault extraction marker file path or hash invalid'}
        $item=Assert-PASeasyVaultEntry $path -Protected
        if($item.PSIsContainer -or $item.Length -ne $file.length -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $file.sha256){throw 'Vault extracted file differs from its pinned marker'}
    }
    $exe=if($Component -eq 'PACLI'){'Pacli.exe'}else{'setup.exe'}
    if(-not @($record.files|Where-Object {$_.path -ieq $exe}).Count){throw 'Vault extraction marker lacks required executable'}
    $true
}
function Expand-PASeasyVaultMedia {
    param([hashtable]$Settings,[string]$Component,[ValidateRange(1,500000)][int]$MaxFiles=50000,[ValidateRange(1,1099511627776)][long]$MaxBytes=21474836480)
    $archive=Get-PASeasyVaultArchiveName $Component
    $packages=Get-PASeasyVaultCanonicalPath ([string]$Settings.PackagesRoot)
    Assert-PASeasyVaultTree $packages -Protected -AllowInheritedDescendants
    $source=Join-Path $packages $archive;$dest=Join-Path $packages $Component
    $null=Assert-PASeasyVaultEntry $source -Protected
    if(Test-Path -LiteralPath $dest){$null=Test-PASeasyVaultExtractedMedia $Settings $Component;return $false}
    if(Test-Path -LiteralPath ($dest+'.partial')){throw 'Legacy partial Vault media requires explicit reconciliation; nothing was removed'}
    $tag=$Component.Replace(' ','_')
    if(@(Get-ChildItem -LiteralPath $packages -Force|Where-Object {$_.Name -like ('.paeasy-extract-'+$tag+'-*')}).Count){throw 'An interrupted private Vault extraction requires explicit reconciliation; nothing was removed'}
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($source);$temp=$null
    try{
        if($zip.Entries.Count -gt $MaxFiles){throw 'Vault archive file-count limit exceeded'}
        $names=New-Object 'System.Collections.Generic.Dictionary[string,bool]' ([StringComparer]::OrdinalIgnoreCase)
        $prepared=New-Object System.Collections.ArrayList;$total=[long]0
        $caseNames=New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach($entry in $zip.Entries){
            $raw=$entry.FullName.Replace('\','/')
            if(-not $raw -or $raw.StartsWith('/') -or $raw.Contains(':')){throw 'Vault archive contains an absolute or ADS path'}
            $directory=$raw.EndsWith('/');$name=$raw.TrimEnd('/')
            foreach($part in $name.Split('/')){if(-not $part -or $part -in @('.','..') -or $part -ne $part.TrimEnd(' ','.') -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)' -or $part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0){throw 'Vault archive contains an unsafe Windows path component'}}
            $kind=($entry.ExternalAttributes -shr 16) -band 61440
            if($kind -notin @(0,16384,32768) -or ($entry.ExternalAttributes -band 1024)){throw 'Vault archive links and special files prohibited'}
            if($name -ieq '.paeasy-extracted.json' -or $names.ContainsKey($name)){throw 'Vault archive contains reserved marker or duplicate/case aliases'}
            $prefix='';foreach($segment in $name.Split('/')){if($prefix){$prefix+='/' };$prefix+=$segment;if($caseNames.ContainsKey($prefix) -and $caseNames[$prefix] -cne $prefix){throw 'Vault archive contains case-aliased directory paths'};if(-not $caseNames.ContainsKey($prefix)){$caseNames.Add($prefix,$prefix)}}
            $names.Add($name,$directory)
            if($entry.Length -lt 0 -or $entry.Length -gt ($MaxBytes-$total)){throw 'Vault archive expanded-size limit exceeded'}
            $total+=$entry.Length;[void]$prepared.Add(@{Entry=$entry;Name=$name;Directory=$directory})
        }
        foreach($item in $prepared){$prefix=$item.Name;while($prefix.Contains('/')){$prefix=$prefix.Substring(0,$prefix.LastIndexOf('/'));if($names.ContainsKey($prefix) -and -not $names[$prefix]){throw 'Vault archive file shadows directory'}}}
        $exe=if($Component -eq 'PACLI'){'Pacli.exe'}else{'setup.exe'}
        if(-not $names.ContainsKey($exe) -or $names[$exe]){throw 'Vault archive lacks required executable'}
        $archiveHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        # Only after complete ZIP admission create one private, known-owned extraction root.
        $temp=Join-Path $packages ('.paeasy-extract-'+$tag+'-'+[guid]::NewGuid().ToString('N'))
        New-PASeasyVaultDirectory $temp
        $files=New-Object System.Collections.ArrayList;$written=[long]0;$buffer=New-Object byte[] 65536
        foreach($item in $prepared){
            $relative=$item.Name.Replace('/','\');$target=Get-PASeasyVaultCanonicalPath (Join-Path $temp $relative)
            if(-not $target.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Vault archive escaped private extraction'}
            if($item.Directory){New-PASeasyVaultDirectory $target;continue}
            New-PASeasyVaultDirectory ([IO.Path]::GetDirectoryName($target))
            $input=$item.Entry.Open();$output=$null
            try{
                $output=Invoke-PASeasyWithRestorePrivilege {[IO.FileStream]::new($target,[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::FullControl,[IO.FileShare]::None,65536,[IO.FileOptions]::None,(New-PASeasyVaultSecurity $false))}
                $length=[long]0
                while(($read=$input.Read($buffer,0,$buffer.Length)) -gt 0){if($read -gt ($MaxBytes-$written)){throw 'Vault archive actual expanded-size limit exceeded'};$written+=$read;$length+=$read;$output.Write($buffer,0,$read)}
                if($length -ne $item.Entry.Length){throw 'Vault archive entry size mismatch'}
                $output.Flush($true)
            }finally{if($output){$output.Dispose()};$input.Dispose()}
            [void]$files.Add(@{path=$relative;length=$length;sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash})
        }
        $record=@{schemaVersion=1;component=$Component;archiveSHA256=$archiveHash;files=@($files)}
        Write-PASeasyVaultOwnedFile (Join-Path $temp '.paeasy-extracted.json') ([Text.Encoding]::UTF8.GetBytes(($record|ConvertTo-Json -Depth 8 -Compress))) -CreateNew
        Assert-PASeasyVaultTree $temp -Protected
        [IO.Directory]::Move($temp,$dest);$temp=$null
        $null=Test-PASeasyVaultExtractedMedia $Settings $Component
        $true
    }finally{
        $zip.Dispose()
        # No cleanup of preexisting destinations, legacy .partial, or other attempts.
        if($temp -and (Test-Path -LiteralPath $temp)){Assert-PASeasyVaultTree $temp -Protected;Remove-Item -LiteralPath $temp -Recurse -Force}
    }
}
