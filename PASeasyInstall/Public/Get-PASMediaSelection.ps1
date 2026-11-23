function Get-PASMediaSelection {
    <#
    .SYNOPSIS
    Picks one installer per component from the output of Get-PASMediaInventory.
    .DESCRIPTION
    Returns a hashtable @{ <Component> = <inventory item> } with one entry for each of Vault, PACLI, DR,
    KeyGen, PVWA, CPM, PSM, PSMP, HTML5GW, PTA, License and RecoveryKey that was found. It is the form the -Media
    parameter of New-PASLabConfiguration expects.

    Per component the highest version wins. PSMP prefers the Ubuntu 24 package, then RHEL 9, then
    RHEL 8 (at install time the package that matches the server is used if it lies next to it). A
    plain PAM license is preferred to a Conjur license. At equal versions a plain file is preferred
    to the same installer inside a bundle, which would have to be extracted first.
    .PARAMETER Inventory
    Objects returned by Get-PASMediaInventory.
    .EXAMPLE
    $media = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path D:\CyberArkMedia)
    .EXAMPLE
    $media = Get-PASMediaInventory -Path D:\CyberArkMedia | Get-PASMediaSelection
    $media.GetEnumerator() | ForEach-Object { '{0,-12} {1}' -f $_.Key, $_.Value.Name }

    Shows which file was chosen for each component.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline)]
        [object[]]$Inventory
    )

    begin {
        $all = New-Object System.Collections.ArrayList
    }

    process {
        foreach ($item in @($Inventory)) {
            if ($null -ne $item) {
                [void]$all.Add($item)
            }
        }
    }

    end {
        # Sort keys, most important first. The first item after a descending sort is the choice.
        $byPreference = {
            $rank = 0
            if ($_.Variant -match '^Ubuntu24') {
                $rank = 3
            } elseif ($_.Variant -match '^RHELinux9') {
                $rank = 2
            } elseif ($_.Variant -match '^RHELinux8') {
                $rank = 1
            }
            if ($_.Component -eq 'License' -and $_.Name -notmatch '(?i)conjur') {
                $rank = 1
            }
            $rank
        }
        $byVersion = {
            try {
                [version]($_.Version -replace '^(\d+(\.\d+){0,3}).*$', '$1')
            } catch {
                [version]'0.0'
            }
        }
        $byPlainFile = {
            if ($_.Entry) { 0 } else { 1 }
        }

        # A package that is not a complete ZIP file is chosen only when there is no other.
        $byIntact = {
            if ($_.PSObject.Properties['Damaged'] -and $_.Damaged) { 0 } else { 1 }
        }
        $selection = @{}
        $installable = @($all.ToArray() | Where-Object { $_.Component -in $script:PASMediaInstallable })
        foreach ($group in @($installable | Group-Object -Property Component)) {
            $sorted = @($group.Group | Sort-Object -Descending -Property @{ Expression = $byIntact }, @{ Expression = $byPreference }, @{ Expression = $byVersion }, @{ Expression = $byPlainFile })
            $selection[$group.Name] = $sorted[0]
            $damaged = @($group.Group | Where-Object { $_.PSObject.Properties['Damaged'] -and $_.Damaged })
            foreach ($bad in $damaged) {
                if ($bad -eq $sorted[0]) {
                    Write-Warning ("The only $($group.Name) package, '$($bad.Name)' ($($bad.Source)), is damaged: it is not a complete ZIP file. Download it again, or add a good copy as a single file.")
                } else {
                    Write-Warning ("The $($group.Name) package '$($bad.Name)' ($($bad.Source)) is damaged (not a complete ZIP file) and is not used. Used instead: '$($sorted[0].Name)'.")
                }
            }
        }
        return $selection
    }
}
