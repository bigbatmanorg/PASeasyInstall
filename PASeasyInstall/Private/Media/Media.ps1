# The media catalog is intentionally explicit: only known Vault 15 patterns are auto-selected.
# Never assume an arbitrary ZIP is an installable component based on partial text alone.
function Get-PASMediaRequirements {
    [CmdletBinding()] param([ValidateSet('Primary', 'PrimaryAndDR')][string]$Mode = 'PrimaryAndDR')
    $items = @(
        [pscustomobject]@{
            Key = 'ServerZip'
            Label = 'Vault Server ZIP'
            Pattern = '(?i)(^|[/\\])(server[-_ ].*|vault[-_ ]server.*|privateark[-_ ]server.*)\.zip$'
            Exclude = '(?i)disaster|recovery|padr|pacli|psm|cpm|pvwa'
            Extension = '.zip'
            DR = $false
        },
        [pscustomobject]@{
            Key = 'DisasterRecoveryZip'
            Label = 'Disaster Recovery ZIP'
            Pattern = '(?i)(disaster.?recovery|padr|vault.?dr).*\.zip$'
            Exclude = ''
            Extension = '.zip'
            DR = $true
        },
        [pscustomobject]@{
            Key = 'PACLIZip'
            Label = 'PACLI ZIP'
            Pattern = '(?i)pacli.*\.zip$'
            Exclude = ''
            Extension = '.zip'
            DR = $false
        },
        [pscustomobject]@{
            Key = 'License'
            Label = 'Vault license'
            Pattern = '(?i)(license|licence).*\.xml$'
            Exclude = ''
            Extension = '.xml'
            DR = $false
        },
        [pscustomobject]@{
            Key = 'PublicRecoveryKey'
            Label = 'Public recovery key'
            Pattern = '(?i)recpub\.key$'
            Exclude = ''
            Extension = '.key'
            DR = $false
        },
        [pscustomobject]@{
            Key = 'PAKeyGenExe'
            Label = 'PAKeyGen executable'
            Pattern = '(?i)^pakeygen\.exe$'
            Exclude = ''
            Extension = '.exe'
            DR = $false
        },
        [pscustomobject]@{
            Key = 'PAKeyGenDll1'
            Label = 'PAKeyGen crypto DLL 1'
            Pattern = '(?i)^calibeay32102o\.dll$'
            Exclude = ''
            Extension = '.dll'
            DR = $false
        },
        [pscustomobject]@{
            Key = 'PAKeyGenDll2'
            Label = 'PAKeyGen crypto DLL 2'
            Pattern = '(?i)^cassleay32102o\.dll$'
            Exclude = ''
            Extension = '.dll'
            DR = $false
        },
        [pscustomobject]@{
            Key = 'VaultTemplate'
            Label = 'Vault response template'
            Pattern = '(?i)^vault-iss\.j2$'
            Exclude = ''
            Extension = '.j2'
            DR = $false
        },
        [pscustomobject]@{
            Key = 'DRTemplate'
            Label = 'DR response template'
            Pattern = '(?i)^vaultdr-iss\.j2$'
            Exclude = ''
            Extension = '.j2'
            DR = $true
        },
        [pscustomobject]@{
            Key = 'VCx86'
            Label = 'VC++ 2015-2022 x86'
            Pattern = '(?i)^vc_redist\.x86\.exe$'
            Exclude = ''
            Extension = '.exe'
            DR = $false
        },
        [pscustomobject]@{
            Key = 'VCx64'
            Label = 'VC++ 2015-2022 x64'
            Pattern = '(?i)^vc_redist\.x64\.exe$'
            Exclude = ''
            Extension = '.exe'
            DR = $false
        },
        [pscustomobject]@{
            Key = 'VC2013x86'
            Label = 'VC++ 2013 x86'
            Pattern = '(?i)^(vcredist_x86|vcredist_x86_2013)\.exe$'
            Exclude = ''
            Extension = '.exe'
            DR = $false
        }
    )
    return @($items | Where-Object { $Mode -eq 'PrimaryAndDR' -or -not $_.DR })
}

function Get-PASMediaFileList {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Container) {
        return @(Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction Stop | Where-Object { -not $_.Attributes.ToString().Contains('ReparsePoint') } | ForEach-Object { $_.FullName })
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return @([IO.Path]::GetFullPath($Path)) }
    throw "Media source not found: $Path"
}

function Find-PASMedia {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,
        [ValidateSet('Primary', 'PrimaryAndDR')][string]$Mode = 'PrimaryAndDR',
        [hashtable]$Overrides = @{})
    $files = @(Get-PASMediaFileList -Path $Path)
    $entries = @()
    foreach ($f in $files) {
        $entries += [pscustomobject]@{Path = $f; Name = [IO.Path]::GetFileName($f); IsVirtual = $false }
    }
    # Inspect a top-level bundle's catalog, but do not pass virtual paths into the deployment.
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and [IO.Path]::GetExtension($Path).ToLowerInvariant() -eq '.zip') {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($Path))
        try {
            if ($zip.Entries.Count -gt 50000) { throw 'ZIP contains too many entries' }
            foreach ($item in $zip.Entries) {
                if ($item.Name) {
                    $entries += [pscustomobject]@{
                        Path = ($Path + '!' + $item.FullName)
                        Name = $item.Name
                        IsVirtual = $true
                    }
                }
            }
        } finally { $zip.Dispose() }
    }
    $results = @()
    foreach ($r in @(Get-PASMediaRequirements -Mode $Mode)) {
        $selected = $null
        $candidates = @()
        if ($Overrides.ContainsKey($r.Key) -and $Overrides[$r.Key]) {
            $selected = [IO.Path]::GetFullPath([string]$Overrides[$r.Key])
            if (-not (Test-Path -LiteralPath $selected -PathType Leaf)) { throw "Override for $($r.Key) does not exist: $selected" }
            if ([IO.Path]::GetExtension($selected).ToLowerInvariant() -ne $r.Extension) { throw "Override $($r.Key) has wrong file extension" }
            $candidates = @([pscustomobject]@{Path = $selected; Name = [IO.Path]::GetFileName($selected); IsVirtual = $false })
        } else {
            $candidates = @($entries | Where-Object { $_.Name -match $r.Pattern -and (-not $r.Exclude -or $_.Name -notmatch $r.Exclude) })
            # A basename with a generic filename is not an unambiguous install-media match.
            if ($candidates.Count -eq 1 -and -not $candidates[0].IsVirtual) { $selected = $candidates[0].Path }
        }
        $status = 'Missing'
        if ($selected) { $status = 'Ready' }
        elseif ($candidates.Count -gt 1) { $status = 'Ambiguous' }
        elseif ($candidates.Count -eq 1) { $status = 'InBundle' }
        $results += [pscustomobject]@{Key = $r.Key; Label = $r.Label; Status = $status; Path = $selected;
            Candidates = @($candidates | ForEach-Object { $_.Path }); Required = $true
        }
    }
    return @($results)
}

function Test-PASWantedMediaName {
    # True for a basename that a Vault deployment can use: a required artifact, a Vault Ansible
    # Role package (PAKeyGen/templates/VC2013) or a key archive (only recpub.key is ever taken from it).
    param([string]$Name)
    if (-not $Name) { return $false }
    if ($Name -match '(?i)vault.?ansible.?role.*\.zip$' -or $Name -match '(?i)^keys?([-_ ].*)?\.zip$') { return $true }
    foreach ($r in @(Get-PASMediaRequirements -Mode PrimaryAndDR)) {
        if ($Name -match $r.Pattern -and (-not $r.Exclude -or $Name -notmatch $r.Exclude)) { return $true }
    }
    return $false
}

function Expand-PASMedia {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Destination,
        [long]$MaxTotalBytes = 21474836480, [int]$MaxFiles = 50000,
        # Optional basename predicate: entries it rejects are validated but not written.
        [scriptblock]$Include)
    if (Test-Path -LiteralPath $SourcePath -PathType Container) { return [IO.Path]::GetFullPath($SourcePath) }
    if ([IO.Path]::GetExtension($SourcePath).ToLowerInvariant() -ne '.zip') { throw 'Media bundle must be a directory or ZIP' }
    # A Server/DR/PACLI release ZIP is already the payload. Do not expand it by default.
    $name = [IO.Path]::GetFileName($SourcePath)
    if ($name -match '(?i)^(server[-_ ]|disaster.?recovery|padr[-_ ]|pacli[-_ ])') { return [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($SourcePath)) }
    # Use the same prevalidated atomic extractor as target component payloads.
    # Every entry is checked even when selective import excludes its bytes.
    return (Expand-PASeasyComponentArchive -Source $SourcePath -Destination $Destination -MaxFiles $MaxFiles -MaxBytes $MaxTotalBytes -Include $Include)
}

function Resolve-PASMediaPath {
    # Materializes an outer distribution ZIP once, under the local application cache.
    # Inner Server / DR / PACLI ZIPs remain intact for the original workflow transfers.
    param([Parameter(Mandatory)][string]$SourcePath, [string]$DataRoot = (Get-PASDataRoot))
    $source = [IO.Path]::GetFullPath($SourcePath)
    if (Test-Path -LiteralPath $source -PathType Container) { return $source }
    if (-not(Test-Path -LiteralPath $source -PathType Leaf)) { throw "Media source not found: $source" }
    if ([IO.Path]::GetExtension($source).ToLowerInvariant() -ne '.zip') { throw 'Only a folder or ZIP bundle is supported' }
    if ([IO.Path]::GetFileName($source) -match '(?i)^(server[-_ ]|disaster.?recovery|padr[-_ ]|pacli[-_ ])') {
        return [IO.Path]::GetDirectoryName($source)
    }
    $file = Get-Item -LiteralPath $source
    # 'selective-v2': only Vault-relevant entries are written (not PSM/CPM/... payloads).
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $identity = 'selective-v3|' + $source + '|' + $sourceHash
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)) }finally { $sha.Dispose() }
    $key = ( -join ($hash[0..9] | ForEach-Object { $_.ToString('x2') }))
    $root = Join-Path $DataRoot 'MediaCache'
    $dest = Join-Path $root $key
    $marker = Join-Path $dest '.paseasy-bundle.json'
    if (Test-Path -LiteralPath $marker -PathType Leaf) { return $dest }
    if (-not(Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
    $temp = Join-Path $root ('.staging-' + [guid]::NewGuid().ToString('N'))
    try {
        $null = Expand-PASMedia -SourcePath $source -Destination $temp -Include { param($n) Test-PASWantedMediaName $n }
        Write-PASJsonAtomic -Path (Join-Path $temp '.paseasy-bundle.json') -Data @{
            Source = $source; SHA256 = $sourceHash; Size = $file.Length; ModifiedUtc = $file.LastWriteTimeUtc.ToString('o'); ImportedUtc = [DateTime]::UtcNow.ToString('o')
        }
        if (Test-Path -LiteralPath $dest) { throw 'Media cache race or incomplete extraction; inspect and clean this cache path' }
        Move-Item -LiteralPath $temp -Destination $dest -ErrorAction Stop
        return $dest
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } }
}

function Save-PASZipEntry {
    # Writes one ZIP entry to Path: first to a file of its own, then moved into place. Two media checks at once
    # (the window and a run, or two plans) may write the same file of the same source: neither sees a half
    # written file, and the one that comes second keeps what is there.
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][string]$Path)
    $temp = $Path + '.' + [guid]::NewGuid().ToString('N') + '.part'
    try {
        $entryStream = $Entry.Open()
        $outputStream = [IO.File]::Create($temp)
        try { $entryStream.CopyTo($outputStream) }finally {
            $entryStream.Dispose()
            $outputStream.Dispose()
        }
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            try { [IO.File]::Replace($temp, $Path, [NullString]::Value) } catch [System.IO.IOException] { $null = $_ }
        } else {
            try { [IO.File]::Move($temp, $Path) }
            catch [System.IO.IOException] {
                if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw }
            }
        }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-PASZipEntryNames {
    param([string]$Path)
    $zip = $null
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        return @($zip.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
    } catch { return @() } finally { if ($zip) { $zip.Dispose() } }
}

function Get-PASCacheKey {
    param([IO.FileInfo]$File, [string]$Salt)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $b = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Salt + '|sha256-v2|' + $File.FullName + '|' + (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash)) }
    finally { $sha.Dispose() }
    return ( -join ($b[0..9] | ForEach-Object { $_.ToString('x2') }))
}

function Get-PASComponentPackagePaths {
    # The installer ZIPs of the CPM, PVWA and PSM components of a configuration (they carry the VC++ runtimes),
    # and the package the composer noted for a Vault that is installed without any of them.
    param($Configuration)
    $paths = @()
    $noted = [string](Get-PASValue (Get-PASValue $Configuration 'options' @{}) 'vcRuntimePackage' '')
    if ($noted) {
        $paths += $noted
    }
    foreach ($component in @($Configuration.components | Where-Object { $_ -and [string]$_.type -in @('CPM', 'PVWA', 'PSM') })) {
        $media = ''
        if ($component -is [System.Collections.IDictionary] -and $component.Contains('media')) {
            $media = [string]$component['media']
        }
        if ($media -and $paths -notcontains $media) {
            $paths += $media
        }
    }
    return @($paths)
}

function Resolve-PASMediaProfile {
    # Resolves media that is not visible as loose files, without ever guessing between differing candidates:
    #  1. a nested distribution bundle (ZIP of ZIPs) supplies missing Server/DR/PACLI packages;
    #  2. a licensed Vault Ansible Role ZIP supplies PAKeyGen, its DLLs, VC++ 2013 x86 and the ISS templates;
    #  2b. a CPM, PVWA or PSM package supplies the VC++ 2015-2022 runtimes when they are not there as files;
    #  3. a key archive supplies recpub.key ONLY (private keys are never read or extracted) when every copy is identical.
    # Explicit operator overrides always win and are never replaced.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Profile, [string]$DataRoot = (Get-PASDataRoot),
        # Component packages of the same deployment (CPM, PVWA, PSM ZIPs): searched for the VC++ runtimes.
        [string[]]$ComponentPackages = @())
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    if ($null -eq $Profile.MediaOverrides) { $Profile.MediaOverrides = @{} }
    $Profile.MediaPath = Resolve-PASMediaPath -SourcePath $Profile.MediaPath -DataRoot $DataRoot
    $current = @(Find-PASMedia -Path $Profile.MediaPath -Mode $Profile.Mode -Overrides $Profile.MediaOverrides)
    $zips = @(Get-ChildItem -LiteralPath $Profile.MediaPath -Recurse -File -Filter '*.zip' -ErrorAction Stop |
            Where-Object { -not $_.Attributes.ToString().Contains('ReparsePoint') })

    # 1. Nested distribution bundle: only for packages with no loose candidate at all (never to break a tie).
    $packages = @($current | Where-Object { $_.Status -eq 'Missing' -and $_.Key -in @('ServerZip', 'DisasterRecoveryZip', 'PACLIZip') })
    if ($packages.Count) {
        $reqs = @(Get-PASMediaRequirements -Mode $Profile.Mode)
        $bundles = @($zips | Where-Object {
                $names = @(Get-PASZipEntryNames $_.FullName | ForEach-Object { ($_ -split '/')[-1] })
                $hit = $false
                foreach ($m in $packages) {
                    $r = $reqs | Where-Object Key -eq $m.Key
                    if (@($names | Where-Object { $_ -match $r.Pattern -and (-not $r.Exclude -or
                                    $_ -notmatch $r.Exclude) }).Count) { $hit = $true }
                }
                $hit })
        if ($bundles.Count -eq 1) {
            $expanded = Resolve-PASMediaPath -SourcePath $bundles[0].FullName -DataRoot $DataRoot
            $inner = @(Find-PASMedia -Path $expanded -Mode $Profile.Mode)
            foreach ($m in $packages) {
                $row = @($inner | Where-Object { $_.Key -eq $m.Key -and $_.Status -eq 'Ready' })
                if ($row.Count -eq 1) { $Profile.MediaOverrides[$m.Key] = $row[0].Path }
            }
            $zips += @(Get-ChildItem -LiteralPath $expanded -Recurse -File -Filter '*.zip')
        }
        # More than one bundle: leave Missing; the operator chooses with an explicit override.
        $current = @(Find-PASMedia -Path $Profile.MediaPath -Mode $Profile.Mode -Overrides $Profile.MediaOverrides)
    }

    # 2. Vault Ansible Role assets.
    $map = [ordered]@{
        VaultTemplate = @{Suffix = 'templates/vault-iss.j2'; Relative = 'templates/vault-iss.j2' }
        DRTemplate = @{Suffix = 'templates/vaultdr-iss.j2'; Relative = 'templates/vaultdr-iss.j2' }
        PAKeyGenExe = @{Suffix = 'files/InstallationAutomation/PAKeyGen/PAKeyGen.exe'; Relative = 'PAKeyGen/PAKeyGen.exe' }
        PAKeyGenDll1 = @{
            Suffix = 'files/InstallationAutomation/PAKeyGen/calibeay32102o.dll'
            Relative = 'PAKeyGen/calibeay32102o.dll'
        }
        PAKeyGenDll2 = @{
            Suffix = 'files/InstallationAutomation/PAKeyGen/cassleay32102o.dll'
            Relative = 'PAKeyGen/cassleay32102o.dll'
        }
        VC2013x86 = @{Suffix = 'files/InstallationAutomation/Binaries/vcredist_x86.exe'; Relative = 'vcredist_x86.exe' }
    }
    $needed = @($current | Where-Object { $_.Status -ne 'Ready' -and $map.Contains($_.Key) -and -not $Profile.MediaOverrides[$_.Key] })
    if ($needed.Count) {
        $roles = @($zips | Where-Object {
                $names = @(Get-PASZipEntryNames $_.FullName)
                @($names | Where-Object { $_.EndsWith($map.VaultTemplate.Suffix, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 1 -and
                @($names | Where-Object { $_.EndsWith($map.PAKeyGenExe.Suffix, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 1 })
        # The same role package reachable twice (loose and inside a bundle) is one source, not a conflict.
        $roles = @($roles | Group-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | ForEach-Object { $_.Group[0] })
        if ($roles.Count -gt 1) { throw 'Multiple different Vault Ansible Role archives found. Extract one manually or specify explicit file overrides.' }
        if ($roles.Count -eq 1) {
            $role = $roles[0]
            $dest = Join-Path (Join-Path $DataRoot 'MediaAssets') (Get-PASCacheKey $role 'role-v1')
            $marker = Join-Path $dest '.paseasy-role.json'
            if (-not(Test-Path -LiteralPath $marker)) {
                if (-not(Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
                $zip = [IO.Compression.ZipFile]::OpenRead($role.FullName)
                try {
                    foreach ($row in $map.GetEnumerator()) {
                        $hit = @($zip.Entries | Where-Object { $_.FullName.Replace('\', '/').EndsWith($row.Value.Suffix, [StringComparison]::OrdinalIgnoreCase) })
                        if ($hit.Count -ne 1) { throw "Role package does not contain exactly one $($row.Value.Suffix)" }
                        $to = Join-Path $dest $row.Value.Relative
                        $dir = [IO.Path]::GetDirectoryName($to)
                        if (-not(Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                        Save-PASZipEntry -Entry $hit[0] -Path $to
                    }
                } finally { $zip.Dispose() }
                Write-PASJsonAtomic -Path $marker -Data @{
                    Source = $role.FullName
                    ImportedUtc = [DateTime]::UtcNow.ToString('o')
                }
            }
            foreach ($r in $needed) {
                $path = Join-Path $dest $map[$r.Key].Relative
                if (Test-Path -LiteralPath $path) { $Profile.MediaOverrides[$r.Key] = $path }
            }
        }
    }

    # 2b. VC++ 2015-2022 runtimes. CyberArk ships them inside the CPM, PVWA and PSM packages but not with the
    # Vault. When they are not in the media folder as files, they are taken from the first of those packages
    # that is there (CPM, then PVWA, then PSM; the newest file name first).
    $runtimeMap = @{
        VCx86 = @{ Pattern = '(?i)(^|/)ISSetupPrerequisites/[^/]+/(vc_redist\.x86|vcredist_x86)\.exe$'; Name = 'VC_redist.x86.exe' }
        VCx64 = @{ Pattern = '(?i)(^|/)ISSetupPrerequisites/[^/]+/(vc_redist\.x64|vcredist_x64)\.exe$'; Name = 'VC_redist.x64.exe' }
    }
    $runtimes = @($current | Where-Object { $_.Status -eq 'Missing' -and $runtimeMap.ContainsKey($_.Key) -and -not $Profile.MediaOverrides[$_.Key] })
    if ($runtimes.Count) {
        $source = $null
        $packages = @($zips)
        foreach ($package in @($ComponentPackages | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })) {
            $packages += Get-Item -LiteralPath $package
        }
        foreach ($prefix in @('Central Policy Manager', 'Password Vault Web Access', 'Privileged Session Manager')) {
            foreach ($candidate in @($packages | Where-Object { $_.Name -like ($prefix + '-Rls*.zip') } | Sort-Object Name -Descending)) {
                $names = @(Get-PASZipEntryNames $candidate.FullName)
                $complete = $true
                foreach ($runtime in $runtimes) {
                    if (@($names | Where-Object { $_ -match $runtimeMap[$runtime.Key].Pattern }).Count -ne 1) {
                        $complete = $false
                    }
                }
                if ($complete) {
                    $source = $candidate
                    break
                }
            }
            if ($source) {
                break
            }
        }
        if ($source) {
            $dest = Join-Path (Join-Path $DataRoot 'MediaAssets') (Get-PASCacheKey $source 'vcruntime-v1')
            if (-not (Test-Path -LiteralPath $dest)) {
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
            }
            $zip = [IO.Compression.ZipFile]::OpenRead($source.FullName)
            try {
                foreach ($runtime in $runtimes) {
                    $to = Join-Path $dest $runtimeMap[$runtime.Key].Name
                    if (-not (Test-Path -LiteralPath $to)) {
                        $entry = @($zip.Entries | Where-Object { $_.FullName.Replace('\', '/') -match $runtimeMap[$runtime.Key].Pattern })[0]
                        Save-PASZipEntry -Entry $entry -Path $to
                    }
                    $Profile.MediaOverrides[$runtime.Key] = $to
                }
            } finally {
                $zip.Dispose()
            }
        }
    }

    # 3. Public recovery key from a key archive. Only entries named exactly recpub.key are opened.
    $pub = @($current | Where-Object { $_.Key -eq 'PublicRecoveryKey' -and $_.Status -eq 'Missing' })
    if ($pub.Count -and -not $Profile.MediaOverrides['PublicRecoveryKey']) {
        $copies = @()
        foreach ($z in $zips) {
            if (-not (@(Get-PASZipEntryNames $z.FullName) | Where-Object { ($_ -split '/')[-1] -ieq 'recpub.key' })) { continue }
            $zip = [IO.Compression.ZipFile]::OpenRead($z.FullName)
            try {
                foreach ($e in @($zip.Entries | Where-Object { $_.Name -ieq 'recpub.key' })) {
                    if ($e.Length -gt 65536) { continue }
                    $ms = New-Object IO.MemoryStream
                    $s = $e.Open()
                    try { $s.CopyTo($ms) } finally { $s.Dispose() }
                    $bytes = $ms.ToArray()
                    $h = [Security.Cryptography.SHA256]::Create()
                    try { $hash = [BitConverter]::ToString($h.ComputeHash($bytes)) } finally { $h.Dispose() }
                    $copies += [pscustomobject]@{Hash = $hash; Bytes = $bytes; Source = $z.FullName }
                }
            } finally { $zip.Dispose() }
        }
        $distinct = @($copies | Group-Object Hash)
        if ($distinct.Count -eq 1) {
            $first = $copies[0]
            $dest = Join-Path (Join-Path $DataRoot 'MediaAssets') (Get-PASCacheKey (Get-Item -LiteralPath $first.Source) 'recpub-v1')
            if (-not(Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Force -Path $dest | Out-Null }
            $to = Join-Path $dest 'recpub.key'
            if (-not (Test-Path -LiteralPath $to)) { [IO.File]::WriteAllBytes($to, $first.Bytes) }
            $Profile.MediaOverrides['PublicRecoveryKey'] = $to
        }
        # Differing recpub.key copies: left Missing; the operator must map the intended key explicitly.
    }
    return $Profile
}
