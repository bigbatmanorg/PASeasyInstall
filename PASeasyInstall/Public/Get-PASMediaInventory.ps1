function Get-PASMediaInventory {
    <#
    .SYNOPSIS
    Finds CyberArk installer media in files, folders and ZIP bundles. Read-only.
    .DESCRIPTION
    Recognises the installers by file name. Folders are searched four levels deep. A ZIP bundle (the
    CyberArk distribution ZIP that contains the installer ZIPs) is looked into through its directory
    only; nothing is extracted.

    Returns one object per installer with Component, Name, Version, Variant, Path, Entry, Source and
    Container. Component is Vault, PACLI, DR, KeyGen, PVWA, CPM, PSM, PSMP, License, RecoveryKey,
    Prerequisite, Unknown, or Missing for a path that does not exist. Entry is the path inside a
    bundle and empty for a plain file. Variant is the Linux distribution of a PSMP package.
    .PARAMETER Path
    One or more files or folders to look at.
    .EXAMPLE
    Get-PASMediaInventory -Path D:\CyberArkMedia | Format-Table Component, Version, Variant, Name
    .EXAMPLE
    'D:\CyberArkMedia', 'D:\Licenses\license.xml' | Get-PASMediaInventory | Where-Object Component -eq 'Unknown'

    Shows the files that were not recognised.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string[]]$Path
    )

    begin {
        $items = New-Object System.Collections.ArrayList
    }

    process {
        # Breadth-first walk. Each queue entry is a path and its depth below the path that was given.
        $queue = New-Object System.Collections.Queue
        foreach ($start in $Path) {
            if ($start) {
                $queue.Enqueue(@{ Path = $start; Depth = 0 })
            }
        }
        while ($queue.Count) {
            $next = $queue.Dequeue()
            $current = [string]$next.Path

            if (Test-Path -LiteralPath $current -PathType Container) {
                if ($next.Depth -ge 4) {
                    continue
                }
                foreach ($child in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue)) {
                    # Links and junctions are not followed.
                    if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        continue
                    }
                    $queue.Enqueue(@{ Path = $child.FullName; Depth = $next.Depth + 1 })
                }
                continue
            }

            $name = [IO.Path]::GetFileName($current)
            if (-not (Test-Path -LiteralPath $current -PathType Leaf)) {
                [void]$items.Add((New-PASMediaItem -Path $current -Entry '' -Component 'Missing' -Name $name -Container 'File'))
                continue
            }

            $kind = Get-PASMediaClassification $name
            if ($kind -eq 'Ignore') {
                continue
            }
            if ($kind -ne 'Unknown') {
                [void]$items.Add((New-PASMediaItem -Path $current -Entry '' -Component $kind -Name $name -Container 'File'))
                continue
            }
            # An unknown ZIP may be a bundle that contains installers.
            if ($name -match '(?i)\.zip$') {
                $inner = @(Get-PASZipMedia -Path $current)
                if ($inner.Count) {
                    foreach ($item in $inner) {
                        [void]$items.Add($item)
                    }
                    continue
                }
            }
            # Other files are only listed when they could be media at all.
            if ($name -match '(?i)\.(zip|xml|key|exe|msi|rpm|deb|tar|gz)$') {
                [void]$items.Add((New-PASMediaItem -Path $current -Entry '' -Component 'Unknown' -Name $name -Container 'File'))
            }
        }
    }

    end {
        # The same installer as a plain file and inside a bundle is one choice, not two: keep the plain file.
        $plain = @{}
        foreach ($item in $items) {
            if (-not $item.Entry) {
                $plain[($item.Component + '|' + $item.Name).ToLowerInvariant()] = $true
            }
        }
        return @($items.ToArray() | Where-Object {
                -not $_.Entry -or -not $plain.ContainsKey(($_.Component + '|' + $_.Name).ToLowerInvariant())
            })
    }
}
