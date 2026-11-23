# The screens of the desktop window, built from the controls of Controls.ps1. Every function reads the state
# ($S, see Model.ps1) and fills a part of the window; none of them calls the installer.
#
#   $ui   the named parts of the shell (Window.xaml)
#   $R    the parts of the current page that are filled again on their own (the result of the server check,
#         the status of an installation, ...), by name. Set-PASUIRegion replaces what one of them shows.

function Get-PASUIFlowSteps {
    return @(
        @{ Id = 'media'; Title = 'Media' }
        @{ Id = 'lab'; Title = 'Lab' }
        @{ Id = 'servers'; Title = 'Servers' }
        @{ Id = 'review'; Title = 'Install' }
    )
}

function New-PASUIRegion {
    # A part of the page that is filled again on its own. Returns the (empty) panel and remembers it by name.
    param([string]$Name, [object[]]$Content = @())
    $panel = New-Object Windows.Controls.StackPanel
    Add-PASUIChild $panel $Content
    $R[$Name] = $panel
    return $panel
}

function Set-PASUIRegion {
    # Replaces what a part of the page shows. Nothing happens when the page that has it is not on screen.
    param([string]$Name, [object[]]$Content = @())
    if (-not $R.ContainsKey($Name)) {
        return
    }
    $R[$Name].Children.Clear()
    Add-PASUIChild $R[$Name] $Content
}

function Show-PASUISteps {
    # The step line in the top bar: finished steps with a check mark (they can be pressed), the current one
    # filled, the ones ahead as an outline. Empty outside the four steps of a new lab.
    $ui.Steps.Children.Clear()
    $steps = @(Get-PASUIFlowSteps)
    $ids = @($steps | ForEach-Object { $_.Id })
    $position = [array]::IndexOf($ids, [string]$S.Screen)
    if ($position -lt 0) {
        return
    }
    for ($i = 0; $i -lt $steps.Count; $i++) {
        if ($i -gt 0) {
            $joint = New-Object Windows.Shapes.Rectangle
            $joint.Width = 18
            $joint.Height = 1
            $joint.Margin = '6,0'
            $joint.Fill = Get-PASUIBrush 'LineStrong'
            [void]$ui.Steps.Children.Add($joint)
        }
        $content = New-Object Windows.Controls.StackPanel
        $content.Orientation = 'Horizontal'
        $dot = New-Object Windows.Controls.Border
        $dot.Width = 20
        $dot.Height = 20
        $dot.CornerRadius = '10'
        $dot.BorderThickness = '1'
        $dot.Margin = '0,0,7,0'
        $label = New-PASUIText $steps[$i].Title
        $label.FontSize = 12.5
        $label.VerticalAlignment = 'Center'
        if ($i -eq $position) {
            $dot.Background = Get-PASUIBrush 'Accent'
            $dot.BorderBrush = Get-PASUIBrush 'Accent'
            $number = New-PASUIText ([string]($i + 1))
            $number.Foreground = [Windows.Media.Brushes]::White
            $number.FontWeight = [Windows.FontWeights]::Bold
            $label.FontWeight = [Windows.FontWeights]::SemiBold
        } elseif ($i -lt $position) {
            $dot.Background = Get-PASUIBrush 'OkBg'
            $dot.BorderBrush = Get-PASUIBrush 'OkLine'
            $number = New-PASUIIcon 0xE73E 'OkFg' 10
            $label.Foreground = Get-PASUIBrush 'TextSoft'
        } else {
            $dot.BorderBrush = Get-PASUIBrush 'LineStrong'
            $number = New-PASUIText ([string]($i + 1)) -Brush 'Muted'
            $label.Foreground = Get-PASUIBrush 'Muted'
        }
        if ($number.FontSize -gt 11) {
            $number.FontSize = 11
        }
        $number.HorizontalAlignment = 'Center'
        $number.VerticalAlignment = 'Center'
        $dot.Child = $number
        [void]$content.Children.Add($dot)
        [void]$content.Children.Add($label)
        $step = New-Object Windows.Controls.Button
        $step.Style = $window.Resources['StepButton']
        $step.Content = $content
        $step.Tag = 'step-' + $steps[$i].Id
        $step.IsEnabled = ($i -lt $position)
        [Windows.Automation.AutomationProperties]::SetName($step, ('Step ' + ($i + 1) + ': ' + $steps[$i].Title))
        $step.Add_Click({
                param($sender, $eventArgs)
                $id = [string]$sender.Tag
                Invoke-PASUISafe { Invoke-PASUIClick $id }
            })
        [void]$ui.Steps.Children.Add($step)
    }
}

function Show-PASUIBar {
    # Back and Next at the bottom of the four steps; hidden elsewhere.
    $ui.NextBusy.Visibility = 'Collapsed'
    $ui.NextBusy.Content = $null
    $ui.NextArrow.Visibility = 'Visible'
    $ui.BtnNext.Visibility = 'Visible'
    $ui.BtnNext.IsEnabled = $true
    $ui.BarText.Text = ''
    switch ([string]$S.Screen) {
        'media' {
            $ui.NextText.Text = 'Next: choose the lab'
        }
        'lab' {
            $ui.NextText.Text = 'Next: servers'
        }
        'servers' {
            if ($S.Checking) {
                $ui.NextText.Text = 'Checking...'
                $ui.BarText.Text = 'Checking the servers. Nothing is installed yet.'
                $ui.BtnNext.IsEnabled = $false
                $ui.NextArrow.Visibility = 'Collapsed'
                $ui.NextBusy.Content = New-PASUISpinner 'TextSoft' 14
                $ui.NextBusy.Visibility = 'Visible'
            } else {
                $ui.NextText.Text = 'Next: check the servers'
                $ui.BarText.Text = 'Next checks that every server answers and that the accounts work. Nothing is installed yet.'
            }
        }
        'review' {
            $ui.BtnNext.Visibility = 'Collapsed'
        }
        default {
            $ui.Bar.Visibility = 'Collapsed'
            return
        }
    }
    [Windows.Automation.AutomationProperties]::SetName($ui.BtnNext, [string]$ui.NextText.Text)
    $ui.Bar.Visibility = 'Visible'
}

function Show-PASUINotice {
    # The line under the top bar, from $S.Notice (Kind: busy, ok, error, info, warn; Text).
    if (-not $S.Notice) {
        $ui.Notice.Visibility = 'Collapsed'
        $ui.NoticeIcon.Content = $null
        $ui.NoticeText.Text = ''
        return
    }
    $kind = [string]$S.Notice.Kind
    if ($kind -eq 'error') {
        $kind = 'bad'
    }
    if (-not $script:PASUITones.ContainsKey($kind)) {
        $kind = 'info'
    }
    $tone = $script:PASUITones[$kind]
    $ui.Notice.Background = Get-PASUIBrush $tone.Bg
    $ui.Notice.BorderBrush = Get-PASUIBrush $tone.Line
    $ui.NoticeIcon.Content = New-PASUIToneIcon $kind 15
    $ui.NoticeText.Text = [string]$S.Notice.Text
    $ui.Notice.Visibility = 'Visible'
}

function New-PASUIIssueBox {
    # A red box with what is missing, or nothing when nothing is.
    param([string[]]$Issues, [string]$Title = 'Before you continue')
    $list = @($Issues | Where-Object { $_ })
    if (-not $list.Count) {
        return $null
    }
    return New-PASUIBox 'bad' $Title '' $list
}

# ------------------------------------------------------------------ start page

function Add-PASUIHomePage {
    param($Page)
    $hero = New-PASUICard -Content @(
        (New-PASUIText 'Build a CyberArk PAM lab' 'H1'),
        (New-PASUIText 'Media, lab, servers, install. Nothing is changed on any server before you press Install.' 'Lead' -Margin '0,0,0,16'),
        (New-PASUIRow @(
                (New-PASUIButton 'act-new' 'Start a new lab' 'PrimaryBig'),
                (New-PASUIButton 'act-open' 'Open a saved lab file' 'Big')))
    )
    $hero.Padding = '22,20'
    $runs = New-PASUICard 'Your installations' @((New-PASUIRegion 'Runs'))
    Add-PASUIChild $Page @(
        $hero,
        $runs,
        (New-PASUIText 'PASeasyInstall builds labs. An installation runs in its own process and continues when this window is closed.' 'Hint')
    )
    Show-PASUIRunList
}

function Show-PASUIRunList {
    # The installations of this computer on the start page, newest first.
    if ($S.RunsLoading) {
        Set-PASUIRegion 'Runs' @((New-PASUIText 'Looking for earlier installations...' 'Hint'))
        return
    }
    $runs = @($S.Runs)
    if (-not $runs.Count) {
        Set-PASUIRegion 'Runs' @((New-PASUIText 'No installation has been started from this computer yet.' 'Hint'))
        return
    }
    $rows = @()
    foreach ($run in ($runs | Select-Object -First 12)) {
        $line = New-Object Windows.Controls.DockPanel
        $line.Margin = '0,4,0,4'
        $open = New-PASUIButton ('run-' + [string]$run.RunId) 'Open' 'Small' -Margin '12,0,0,0' -Label ('Open ' + [string]$run.Name)
        [Windows.Controls.DockPanel]::SetDock($open, 'Right')
        $pill = New-PASUIPill (Get-PASUIStatusText ([string]$run.Status)) (Get-PASUIStatusKind ([string]$run.Status))
        [Windows.Controls.DockPanel]::SetDock($pill, 'Right')
        $name = New-Object Windows.Controls.StackPanel
        $name.Orientation = 'Horizontal'
        $name.VerticalAlignment = 'Center'
        Add-PASUIChild $name @(
            (New-PASUIText ([string]$run.Name) -Bold),
            (New-PASUIText ('started ' + (Format-PASUIWhen ([string]$run.StartedUtc))) 'Hint' -Margin '10,1,0,0')
        )
        Add-PASUIChild $line @($open, $pill, $name)
        $rows += $line
    }
    Set-PASUIRegion 'Runs' $rows
}

# ------------------------------------------------------------------ step 1: media

function Add-PASUIMediaPage {
    # Media is added by path only: a folder or files chosen in a dialog, or a path typed or pasted.
    param($Page)
    $line = New-Object Windows.Controls.DockPanel
    $add = New-PASUIButton 'act-media-add' 'Add' 'Primary' -Margin '0,22,0,0' -Label 'Add this path'
    [Windows.Controls.DockPanel]::SetDock($add, 'Right')
    $path = New-PASUITextBox 'f-mediapath' ([string]$S.MediaPath) 'Path of a folder or a file' -Placeholder 'For example D:\CyberArkMedia or D:\Licenses\license.xml'
    $R['MediaPathBox'] = $path
    Add-PASUIChild $line @($add, (New-PASUIField 'Path of a folder or a file' $path -Margin '0,0,10,0'))
    $pick = New-PASUIRow @(
        (New-PASUIButton 'act-browse' 'Choose a folder...' 'Btn'),
        (New-PASUIButton 'act-browse-files' 'Choose files...' 'Btn')
    ) -Margin '0,12,0,0'

    $bullet = [string][char]0x2022 + ' '
    $looksFor = New-PASUICard 'What the window looks for' @(
        (New-PASUIText 'You do not have to sort anything. Add every place where a part of the media lies, one after the other. The window looks through all of them and works out which file is what:' 'Hint' -Margin '0,0,0,8'),
        (New-PASUIText ($bullet + 'the installers of the Vault, PVWA, CPM, PSM, PSMP and the other components: the one big ZIP from CyberArk, or the separate ZIP files') -Brush 'TextSoft' -Margin '0,2,0,2'),
        (New-PASUIText ($bullet + 'the Vault license (license.xml)') -Brush 'TextSoft' -Margin '0,2,0,2'),
        (New-PASUIText ($bullet + 'the recovery public key (recpub.key), from your operator keys') -Brush 'TextSoft' -Margin '0,2,0,2'),
        (New-PASUIText ($bullet + 'the Visual C++ runtimes for the Vault (also taken from the PVWA, CPM or PSM package)') -Brush 'TextSoft' -Margin '0,2,0,2'),
        (New-PASUIText 'A folder is searched four levels deep. ZIP files are looked into; nothing is unpacked, moved or changed.' 'Hint' -Margin '0,8,0,0')
    )

    Add-PASUIChild $Page @(
        (New-PASUIText 'Where is the installer media?' 'H1'),
        (New-PASUIText 'What you downloaded from CyberArk, your license file and your keys. They can lie in different places: add as many folders and single files as you need.' 'Lead' -Margin '0,0,0,18'),
        (New-PASUICard 'Add a folder or a file' @($line, $pick)),
        (New-PASUIRegion 'MediaSources'),
        (New-PASUIRegion 'MediaResult'),
        $looksFor
    )
    Show-PASUIMediaSources
    Show-PASUIMediaResult
}

function Show-PASUIMediaSources {
    # The folders and files that were added, each with what was found in it and a button to remove it.
    $rows = @(Get-PASUIMediaSourceRows $S)
    if (-not $rows.Count) {
        Set-PASUIRegion 'MediaSources'
        return
    }
    $grid = New-PASUIGrid @('*', 'Auto')
    $number = 0
    foreach ($row in $rows) {
        $what = New-Object Windows.Controls.StackPanel
        $what.Margin = '0,5,14,5'
        $found = 'Being looked through...'
        if ($S.MediaScanned) {
            $found = 'Nothing recognised here'
            if ($row.Count) {
                $found = 'Found here: ' + ($row.Labels -join ', ')
            }
        }
        $note = New-PASUIText $found 'Hint'
        if ($S.MediaScanned -and $row.Missing) {
            $note = New-PASUIText 'This folder or file does not exist. Remove it and add the right path.' -Brush 'BadFg'
        }
        Add-PASUIChild $what @((New-PASUIText ([string]$row.Path)), $note)
        $remove = New-PASUIButton ('act-media-remove-' + [string]$row.Index) 'Remove' 'Small' -Margin '0,5,0,5' -Label ('Remove ' + [string]$row.Path)
        $remove.VerticalAlignment = 'Top'
        Add-PASUICell $grid $what $number 0
        Add-PASUICell $grid $remove $number 1
        $number++
    }
    $title = 'Where the window looks (' + [string]$rows.Count + ')'
    Set-PASUIRegion 'MediaSources' @((New-PASUICard $title @($grid)))
}

function Show-PASUIMediaResult {
    # What was recognised in everything that was added: one line per kind of media, with the place it came from.
    if ($S.Scanning) {
        Set-PASUIRegion 'MediaResult' @((New-PASUIBox 'busy' 'Looking for installers.' 'Folders and ZIP files are looked through. This takes a few seconds.'))
        return
    }
    if (-not $S.MediaScanned) {
        Set-PASUIRegion 'MediaResult'
        return
    }
    $rows = @(Get-PASUIMediaRows $S)
    if (-not @($rows | Where-Object { $_.Found }).Count) {
        Set-PASUIRegion 'MediaResult' @((New-PASUIBox 'bad' 'No CyberArk installer was recognised.' 'Add the folder with the ZIP files as downloaded from CyberArk, not an unpacked copy.'))
        return
    }
    $grid = New-PASUIGrid @('Auto', '2*', '3*')
    Add-PASUICell $grid (New-PASUIText ' ' 'ColHead' -Margin '0,0,14,6') 0 0
    Add-PASUICell $grid (New-PASUIText 'What' 'ColHead' -Margin '0,0,14,6') 0 1
    Add-PASUICell $grid (New-PASUIText 'Found in' 'ColHead' -Margin '0,0,0,6') 0 2
    $number = 1
    foreach ($row in $rows) {
        $pill = New-PASUIPill 'not found' 'idle'
        if ($row.Found) {
            $pill = New-PASUIPill 'found' 'ok'
        }
        $pill.Margin = '0,5,14,5'
        $pill.VerticalAlignment = 'Top'
        $what = New-Object Windows.Controls.StackPanel
        $what.Margin = '0,4,14,4'
        Add-PASUIChild $what @((New-PASUIText ([string]$row.Label)))
        if ([string]$row.Detail) {
            Add-PASUIChild $what @((New-PASUIText ([string]$row.Detail) 'Hint'))
        }
        $where = New-Object Windows.Controls.StackPanel
        $where.Margin = '0,4,0,4'
        if ([string]$row.Source) {
            Add-PASUIChild $where @((New-PASUIText ([string]$row.Source) -Brush 'TextSoft'))
            if ([string]$row.Inside) {
                Add-PASUIChild $where @((New-PASUIText ('inside ' + [string]$row.Inside) 'Hint'))
            }
        }
        Add-PASUICell $grid $pill $number 0
        Add-PASUICell $grid $what $number 1
        Add-PASUICell $grid $where $number 2
        $number++
    }
    $content = @((New-PASUICard 'What was found' @($grid)))
    $missing = @(Get-PASUIMissingMedia $S)
    if ($missing.Count) {
        $content += New-PASUIBox 'warn' 'Not found yet for the lab that is chosen:' 'Add the folder or file that holds them, or leave these parts out of the lab on the next step.' $missing
    } else {
        $content += New-PASUIBox 'ok' 'Everything the chosen lab needs was found.' 'You can still add more. Parts that are not found can be left out of the lab on the next step.'
    }
    Set-PASUIRegion 'MediaResult' $content
}

# ------------------------------------------------------------------ step 2: lab

function Add-PASUILabPage {
    param($Page)
    $presets = New-Object Windows.Controls.WrapPanel
    foreach ($preset in Get-PASUIPresets) {
        $note = ''
        if ($preset.Counts) {
            $copy = @{ VaultMode = $preset.VaultMode; Counts = $preset.Counts; Colocate = [bool]$S.Colocate; Domain = 'None' }
            $note = [string]@(Get-PASUIServerSlots $copy).Count + ' servers'
        }
        $badge = ''
        if ($preset.ContainsKey('Recommended')) {
            $badge = 'recommended'
        }
        Add-PASUIChild $presets @((New-PASUIChoice ('preset-' + $preset.Id) $preset.Title $preset.What ($S.Preset -eq $preset.Id) $note $badge))
    }
    Add-PASUIChild $Page @(
        (New-PASUIText 'What do you want to build?' 'H1'),
        (New-PASUIText 'Pick a ready-made lab. You can change every part with Custom.' 'Lead' -Margin '0,0,0,18'),
        $presets
    )
    if ($S.Preset -eq 'custom') {
        Add-PASUIChild $Page @((New-PASUICustomLabCard))
    }
    if ([int]$S.Counts.PVWA -gt 0 -and [int]$S.Counts.CPM -gt 0) {
        # In every lab that has both: CPM next to PVWA, or on a server of its own.
        Add-PASUIChild $Page @((New-PASUICard 'Server for CPM' @(
                    (New-PASUICheck 'f-colocate' 'Install CPM on the PVWA server (one server less)' ([bool]$S.Colocate)),
                    (New-PASUIText 'Switch it off to give CPM a server of its own. The Servers step then has one more line.' 'Hint' -Margin '0,6,0,0'))))
    }

    if ([int]$S.Counts.PSMP -gt 0 -and [int]$S.Counts['HTML5GW'] -gt 0) {
        # In every lab that has both: the gateway next to PSM for SSH, or on a server of its own.
        Add-PASUIChild $Page @((New-PASUICard 'Server for the HTML5 Gateway' @(
                    (New-PASUICheck 'f-colocate-gw' 'Install the HTML5 Gateway on the PSM for SSH server (one server less)' ([bool]$S.ColocateGw)),
                    (New-PASUIText 'Switch it off to give the gateway a Linux server of its own. The Servers step then has one more line.' 'Hint' -Margin '0,6,0,0'))))
    }

    $domains = New-Object Windows.Controls.WrapPanel
    $options = @(
        @{ Id = 'None'; Title = 'No domain'; What = 'The servers stay as they are.' }
        @{ Id = 'New'; Title = 'New domain'; What = 'One more server becomes the domain controller. PVWA, CPM and PSM servers join it and get the CyberArk hardening GPOs.' }
        @{ Id = 'Existing'; Title = 'A domain I already have'; What = 'PVWA, CPM and PSM servers join it. Its GPOs are not touched.' }
    )
    foreach ($option in $options) {
        Add-PASUIChild $domains @((New-PASUIChoice ('domain-' + $option.Id) $option.Title $option.What ($S.Domain -eq $option.Id) -Width 250))
    }
    $domainCard = New-PASUICard 'Active Directory' @($domains)
    if ($S.Domain -ne 'None') {
        Add-PASUIChild $domainCard.Child @((New-PASUIField 'DNS name of the domain' (New-PASUITextBox 'f-domainname' ([string]$S.DomainName) 'DNS name of the domain' 260) `
                    'For example pam.lab. The servers restart once when they join. Vault servers are never joined.' -Margin '0,4,0,0'))
    }
    Add-PASUIChild $Page @(
        $domainCard,
        (New-PASUICard -Content @((New-PASUIField 'Name of the lab' (New-PASUITextBox 'f-labname' ([string]$S.LabName) 'Name of the lab' 260) `
                        'Installations are listed under this name. Letters, digits, dot, dash, underscore.' -Margin '0'))),
        (New-PASUIRegion 'LabIssues' @((New-PASUIIssueBox (Get-PASUIInputIssues $S 'lab'))))
    )
}

function New-PASUICustomLabCard {
    # The Custom lab: the Vault option and how many of each component.
    $modes = New-Object Windows.Controls.WrapPanel
    $options = @(
        @{ Id = 'Primary'; Title = 'New Vault'; What = 'One Vault server.' }
        @{ Id = 'PrimaryDR'; Title = 'New Vault with DR'; What = 'A Vault and a DR Vault that replicates it.' }
        @{ Id = 'Existing'; Title = 'A Vault I already have'; What = 'Only add components to it.' }
    )
    foreach ($option in $options) {
        Add-PASUIChild $modes @((New-PASUIChoice ('vault-' + $option.Id) $option.Title $option.What ($S.VaultMode -eq $option.Id) -Width 250))
    }
    $grid = New-PASUIGrid @('*', 'Auto')
    $max = Get-PASUIMaxCount $S
    $number = 0
    foreach ($type in $script:PASUIComponentTypes) {
        $what = New-Object Windows.Controls.StackPanel
        $what.VerticalAlignment = 'Center'
        $what.Margin = '0,5,0,5'
        Add-PASUIChild $what @((New-PASUIText ([string]$script:PASUITypeNames[$type])))
        if (-not $S.MediaSelection.ContainsKey($type) -and $S.MediaScanned) {
            Add-PASUIChild $what @((New-PASUIText 'no installer in the media folder' 'Hint'))
        }
        $counter = New-Object Windows.Controls.StackPanel
        $counter.Orientation = 'Horizontal'
        $counter.VerticalAlignment = 'Center'
        $value = New-PASUIText ([string][int]$S.Counts[$type]) -Bold
        $value.Width = 34
        $value.TextAlignment = 'Center'
        $value.VerticalAlignment = 'Center'
        Add-PASUIChild $counter @(
            (New-PASUIButton "cnt-$type-dec" '-' 'Small' -Margin '0' -Label "Fewer $type"),
            $value,
            (New-PASUIButton "cnt-$type-inc" '+' 'Small' -Margin '0' -Label "More $type")
        )
        Add-PASUICell $grid $what $number 0
        Add-PASUICell $grid $counter $number 1
        $number++
    }
    return New-PASUICard 'Vault' @(
        $modes,
        (New-PASUIText 'Components' 'H2' -Margin '0,6,0,6'),
        $grid,
        (New-PASUIText "Up to $max of each. Two of each were tested; the Vault license decides how many can register." 'Hint' -Margin '0,6,0,0')
    )
}

# ------------------------------------------------------------------ step 3: servers

function Add-PASUIServersPage {
    param($Page)
    $grid = New-PASUIGrid @('Auto', '*', '*', '*', '*')
    $column = 0
    foreach ($header in @('Server for', 'Computer name', 'Address', 'Account', 'Password')) {
        $cell = New-PASUIText $header 'ColHead' -Margin '0,0,10,6'
        Add-PASUICell $grid $cell 0 $column
        $column++
    }
    $row = 1
    foreach ($slot in Get-PASUIServerSlots $S) {
        $key = [string]$slot.Key
        $role = [string]$slot.Roles
        $roleCell = New-Object Windows.Controls.StackPanel
        $roleCell.VerticalAlignment = 'Center'
        $roleCell.Margin = '0,4,14,4'
        $roleCell.MaxWidth = 170
        $osTag = New-PASUIPill ([string]$slot.Os) 'idle'
        $osTag.Margin = '0,3,0,0'
        Add-PASUIChild $roleCell @((New-PASUIText $role -Bold), $osTag)
        Add-PASUICell $grid $roleCell $row 0
        if ($slot.Named) {
            Add-PASUICell $grid (New-PASUITextBox "srv-$key-name" (Get-PASUISlotValue $S $slot 'Name') "Computer name of the $role server") $row 1
        } else {
            $none = New-PASUIText 'not needed' -Brush 'Muted'
            $none.FontStyle = 'Italic'
            $none.VerticalAlignment = 'Center'
            Add-PASUICell $grid $none $row 1
        }
        Add-PASUICell $grid (New-PASUITextBox "srv-$key-addr" (Get-PASUISlotValue $S $slot 'Address') "Address of the $role server" -Placeholder 'IP address or DNS name') $row 2
        Add-PASUICell $grid (New-PASUITextBox "srv-$key-user" (Get-PASUISlotValue $S $slot 'User') "Account on the $role server") $row 3
        Add-PASUICell $grid (Get-PASUIPasswordBox "srv-$key-pass" "Password on the $role server") $row 4
        $row++
    }
    $servers = New-PASUICard 'Servers' @(
        $grid,
        (New-PASUIText 'Computer name: the name the server already has. PVWA is reached under this name. Account: a local administrator on Windows, root on Linux.' 'Hint' -Margin '0,10,0,0')
    )
    if ($S.Domain -eq 'New') {
        Add-PASUIChild $servers.Child @((New-PASUIText 'Domain controller: its administrator becomes the administrator of the new domain, with the same password. That password is also set as the restore mode password of the domain.' 'Hint' -Margin '0,6,0,0'))
    }
    if ($S.Domain -eq 'Existing') {
        Add-PASUIChild $servers.Child @((New-PASUIText 'Existing domain: the address of one of its DNS servers (usually a domain controller), and a domain account that may join computers.' 'Hint' -Margin '0,6,0,0'))
    }
    $R['ServersGrid'] = $grid

    $vault = New-PASUICard 'Vault'
    if ($S.VaultMode -eq 'Existing') {
        Add-PASUIChild $vault.Child @((New-PASUIField 'Address of the Vault you already have' (New-PASUITextBox 'f-existing' ([string]$S.ExistingVault) 'Address of the Vault you already have' 260)))
    }
    $fields = New-Object Windows.Controls.Primitives.UniformGrid
    $fields.Rows = 1
    foreach ($field in Get-PASUIVaultSecrets $S) {
        Add-PASUIChild $fields @((New-PASUIField ([string]$field.Label) (Get-PASUIPasswordBox ('sec-' + [string]$field.Key) ([string]$field.Label)) ([string]$field.Hint)))
    }
    Add-PASUIChild $vault.Child @($fields)
    $R['VaultFields'] = $fields
    if ([int]$S.Counts.PSMP -gt 0 -or [int]$S.Counts['HTML5GW'] -gt 0 -or [int]$S.Counts['PTA'] -gt 0) {
        Add-PASUIChild $vault.Child @((New-PASUICheck 'f-eula' 'I have read and accept the CyberArk end user license agreement of the Linux installers (PSMP, HTML5 Gateway, PTA)' ([bool]$S.AcceptEula)))
    }
    $lock = New-Object Windows.Controls.StackPanel
    $lock.Orientation = 'Horizontal'
    $lock.Margin = '0,10,0,0'
    $lockIcon = New-PASUIIcon 0xE72E 'Muted' 12
    $lockIcon.Margin = '0,2,7,0'
    Add-PASUIChild $lock @($lockIcon, (New-PASUIText 'Passwords are kept in memory only, never in a file.' 'Hint'))
    Add-PASUIChild $vault.Child @($lock)

    Add-PASUIChild $Page @(
        (New-PASUIText 'Which servers?' 'H1'),
        (New-PASUIText 'Freshly installed machines this computer can reach: Windows with WinRM over HTTPS, Linux with SSH. For each one, the account that may administer it.' 'Lead' -Margin '0,0,0,18'),
        $servers,
        $vault
    )
    if ($S.Advanced) {
        Add-PASUIChild $Page @(
            (New-PASUICard 'Network' @((New-PASUIField 'Address of this computer' (New-PASUITextBox 'f-controller' ([string]$S.Controller) 'Address of this computer' 220) `
                            'As the Vault sees it. The hardened Vault firewall is opened for it.' -Margin '0'))),
            (New-PASUICard 'Who installs' @(
                    (New-PASUIRow @(
                            (New-PASUIField 'User name' (New-PASUITextBox 'f-installer-name' ([string]$S.InstallerName) 'User name' 220)),
                            (New-PASUIField 'Company' (New-PASUITextBox 'f-installer-company' ([string]$S.InstallerCompany) 'Company' 220)))),
                    (New-PASUIText 'What the CyberArk installers record as registered user and company. Empty: the CyberArk defaults.' 'Hint'))),
            (New-PASUICard 'Hardening' @(
                    (New-PASUICheck 'f-hardening' 'Apply the vendor hardening' ([bool]$S.Hardening)),
                    (New-PASUIText 'On: every server is hardened the way CyberArk prescribes (the Vault firewall and services, PVWA, CPM, PSM, PSMP, and the hardening GPOs of a new domain). Switch it off only for tests that need servers without these security settings: everything is installed and registered, nothing is hardened.' 'Hint' -Margin '0,6,0,0')))
        )
        if ([int]$S.Counts['PTA'] -gt 0) {
            Add-PASUIChild $Page @((New-PASUICard 'PTA' @((New-PASUIField 'Time zone of the Vault server' (New-PASUITextBox 'f-vault-timezone' ([string]$S.VaultTimezone) 'Time zone of the Vault server' 220 -Placeholder 'UTC') `
                                'A tz database name such as Europe/Berlin. PTA reads the times in the Vault audit with it. Empty: UTC.' -Margin '0'))))
        }
    }
    $saveLab = New-PASUIButton 'act-save' 'Save the lab file...' 'Btn' -Margin '0'
    $saveLab.HorizontalAlignment = 'Left'
    Add-PASUIChild $Page @(
        (New-PASUICard 'Keep these entries' @(
                $saveLab,
                (New-PASUIText 'Saves the lab, the servers, their names and accounts as a file, so that you need not type them again. Passwords are never saved. Open it later with "Open a saved lab file" on the start page.' 'Hint' -Margin '0,8,0,0'))),
        (New-PASUIRegion 'ServersIssues'),
        (New-PASUIRegion 'PreflightResult')
    )
    Show-PASUIPreflight
}

function Show-PASUIPreflight {
    # The server check on the Servers step: which part is running, or its result. Problems in full; what
    # passed as a count, and every check line by line in the advanced view.
    if ($R.ContainsKey('ServersGrid')) {
        $R['ServersGrid'].IsEnabled = -not $S.Checking
        $R['VaultFields'].IsEnabled = -not $S.Checking
    }
    if ($S.Checking) {
        # The servers of a configuration are a table keyed by their id.
        $count = 0
        if ($S.Configuration -and $S.Configuration.hosts -is [System.Collections.IDictionary]) {
            $count = $S.Configuration.hosts.Count
        }
        $servers = 'the servers'
        if ($count -eq 1) {
            $servers = 'the server'
        } elseif ($count -gt 1) {
            $servers = "the $count servers"
        }
        $box = New-PASUIBox 'busy' 'Checking the servers, part 2 of 2.' "All of them answer. Now signing in to $servers and checking that each is ready. This takes up to a minute per server; nothing is installed."
        if ([string]$S.CheckPhase -eq 'plan') {
            $box = New-PASUIBox 'busy' 'Checking the servers.' 'Getting ready...'
        } elseif ([string]$S.CheckPhase -eq 'reach') {
            $box = New-PASUIBox 'busy' 'Checking the servers, part 1 of 2.' "Looking whether $servers answer. This takes a few seconds."
        }
        Set-PASUIRegion 'PreflightResult' @($box)
        return
    }
    if (-not $S.Preflight) {
        Set-PASUIRegion 'PreflightResult'
        return
    }
    $rows = @($S.Preflight)
    $failed = @($rows | Where-Object { $_.Passed -is [bool] -and -not $_.Passed })
    $passed = @($rows | Where-Object { $_.Passed -is [bool] -and $_.Passed })
    $content = @()
    if ($failed.Count) {
        $items = @($failed | ForEach-Object { (([string]$_.Address + ' ' + [string]$_.Server).Trim()) + ': ' + [string]$_.Detail })
        $content += New-PASUIBox 'bad' 'The servers are not ready.' 'Correct this, then press Next again.' $items
    } else {
        $content += New-PASUIBox 'ok' 'All servers answered and look ready.' "$($passed.Count) checks passed."
    }
    if ($S.Advanced) {
        $list = New-PASUIList 'CheckRow' @($rows | ForEach-Object {
                $result = 'skipped'
                if ($_.Passed -is [bool] -and $_.Passed) {
                    $result = 'ok'
                } elseif ($_.Passed -is [bool]) {
                    $result = 'problem'
                }
                [pscustomobject]@{ Result = $result; Server = [string]$_.Server; Address = [string]$_.Address; Check = [string]$_.Check; Detail = [string]$_.Detail }
            })
        $card = New-PASUICard -Flat -Content @($list)
        [Windows.Controls.Grid]::SetIsSharedSizeScope($card.Child, $true)
        $content += $card
    }
    Set-PASUIRegion 'PreflightResult' $content
}

# ------------------------------------------------------------------ step 4: review and install

function Add-PASUIReviewPage {
    param($Page)
    Add-PASUIChild $Page @((New-PASUIText 'Review and install' 'H1'))
    $check = $S.Check
    if (-not $check) {
        Add-PASUIChild $Page @((New-PASUIBox 'bad' 'The plan could not be prepared.' 'Go back and check the entries.'))
        return
    }
    $issues = @($check.Issues)
    if ($issues.Count) {
        Add-PASUIChild $Page @(
            (New-PASUIText 'The plan has problems. Nothing can be installed until they are solved.' 'Lead' -Margin '0,0,0,18'),
            (New-PASUIIssueBox $issues 'To solve')
        )
        return
    }
    $minutes = Get-PASUIEstimateMinutes $S
    $grid = New-PASUIGrid @('Auto', '2*', '2*', '3*')
    $column = 0
    foreach ($header in @('#', 'What', 'On server', 'Installer')) {
        Add-PASUICell $grid (New-PASUIText $header 'ColHead' -Margin '0,0,14,6') 0 $column
        $column++
    }
    $number = 0
    foreach ($item in @($S.Plan.Items)) {
        $number++
        $media = ''
        if ([string]$item.Media) {
            $media = [IO.Path]::GetFileName([string]$item.Media)
        }
        $where = New-Object Windows.Controls.StackPanel
        $where.Margin = '0,4,14,4'
        Add-PASUIChild $where @((New-PASUIText ([string]$item.Address)), (New-PASUIText ([string]$item.Name) 'Hint'))
        Add-PASUICell $grid (New-PASUIText ([string]$number) -Brush 'Muted' -Margin '0,4,14,4') $number 0
        Add-PASUICell $grid (New-PASUIText ([string]$script:PASUITypeNames[[string]$item.Type]) -Bold -Margin '0,4,14,4') $number 1
        Add-PASUICell $grid $where $number 2
        Add-PASUICell $grid (New-PASUIText $media 'Hint' -Margin '0,5,0,4') $number 3
    }
    Add-PASUIChild $Page @(
        (New-PASUIText "This is what will be installed. It takes about $minutes minutes and needs no attention while it runs." 'Lead' -Margin '0,0,0,18'),
        (New-PASUICard -Content @($grid))
    )
    if (-not $S.Hardening) {
        Add-PASUIChild $Page @((New-PASUIRegion 'ReviewHardening' @((New-PASUIBox 'warn' 'The servers will NOT be hardened.' 'You switched off "Apply the vendor hardening". The components are installed and registered, but the Vault, PVWA, CPM, PSM and PSMP servers keep their unhardened settings. Use such a lab for tests only.'))))
    }
    $warnings = @($check.Warnings | Where-Object { $_ })
    if ($warnings.Count) {
        Add-PASUIChild $Page @((New-PASUIBox 'warn' "Lab shortcuts in use ($($warnings.Count))." 'Fine for a lab, not for production.' $warnings))
    }
    if ($S.Advanced) {
        $save = New-PASUIButton 'act-save' 'Save the lab file' 'Btn' -Margin '0,10,0,0'
        $save.HorizontalAlignment = 'Left'
        Add-PASUIChild $Page @((New-PASUICard 'The same from PowerShell' @(
                    (New-PASUIText 'Everything this window does can be done from the prompt. The lab file holds the choices, never a password.' 'Hint'),
                    (New-PASUIPre (Get-PASUICommandText $S)),
                    $save)))
    } else {
        $save = New-PASUIButton 'act-save' 'Save the lab file...' 'Btn' -Margin '0'
        $save.HorizontalAlignment = 'Left'
        Add-PASUIChild $Page @((New-PASUICard 'Keep these entries' @(
                    $save,
                    (New-PASUIText 'Saves the lab and its servers as a file, without any password. Open it later with "Open a saved lab file" on the start page.' 'Hint' -Margin '0,8,0,0'))))
    }
    $install = New-PASUIButton 'act-install' 'Install the lab' 'PrimaryBig' -Margin '0'
    $install.HorizontalAlignment = 'Left'
    $R['InstallButton'] = $install
    $hero = New-PASUICard -Content @(
        $install,
        (New-PASUIText 'The installation runs in its own process. You can close this window and open it again later.' 'Hint' -Margin '0,10,0,0')
    )
    Add-PASUIChild $Page @($hero)
}

# ------------------------------------------------------------------ the page of one installation

function Add-PASUIRunPage {
    # Built from parts that are filled again on their own, so a refresh leaves the scroll position and the
    # opened activity log as they are.
    param($Page)
    if (-not $S.Run) {
        Add-PASUIChild $Page @((New-PASUIBox 'bad' 'This installation could not be read.'))
        return
    }
    $toggle = New-PASUIButton 'act-log' 'Activity log' 'Ghost' -Margin '0'
    $toggle.Padding = '4,0'
    $last = New-PASUIText '' 'Hint' -Margin '12,0,0,0'
    $last.VerticalAlignment = 'Center'
    $last.TextTrimming = 'CharacterEllipsis'
    $last.TextWrapping = 'NoWrap'
    $R['RunLast'] = $last
    $head = New-Object Windows.Controls.DockPanel
    [Windows.Controls.DockPanel]::SetDock($toggle, 'Left')
    Add-PASUIChild $head @($toggle, $last)
    $logCard = New-PASUICard -Content @($head, (New-PASUIRegion 'RunLog'))
    $logCard.Padding = '12,8'
    if ($S.Advanced) {
        $S.LogOpen = $true
    }
    Add-PASUIChild $Page @(
        (New-PASUIRegion 'RunStatus'),
        (New-PASUICard -Content @((New-PASUIRegion 'RunComps'))),
        (New-PASUIRegion 'RunAdvanced'),
        $logCard
    )
    Show-PASUIRunParts
}

function Show-PASUIRunParts {
    # Fills every part of the installation page from $S.Run.
    Show-PASUIRunStatus
    Show-PASUIRunComponents
    Show-PASUIRunLog
    Show-PASUIRunAdvanced
}

function Show-PASUIRunStatus {
    # Name, status, progress bar and what to do next; below it the result of the lab check.
    $run = $S.Run
    $status = [string]$run.Status
    $kind = Get-PASUIStatusKind $status
    $progress = Get-PASUIRunProgress -Snapshot $run -Catalog $Catalog -PlanItems $S.RunPlan
    $elapsed = ''
    if ($run.PSObject.Properties['StartedUtc']) {
        $finished = ''
        if ($run.PSObject.Properties['FinishedUtc']) {
            $finished = [string]$run.FinishedUtc
        }
        $elapsed = Format-PASUIDuration ([string]$run.StartedUtc) $finished
    }
    $line = "$($progress.Done) of $($progress.Total) steps"
    if ($elapsed) {
        $line += ", $elapsed"
    }
    $head = New-Object Windows.Controls.WrapPanel
    $head.Margin = '0,0,0,8'
    $name = New-PASUIText ([string]$run.Name) 'H1' -Margin '0,0,14,0'
    $count = New-PASUIText $line -Brush 'TextSoft' -Margin '14,0,0,0'
    $count.VerticalAlignment = 'Center'
    Add-PASUIChild $head @($name, (New-PASUIPill (Get-PASUIStatusText $status) $kind), $count)
    $meter = New-PASUIMeter $progress.Percent $kind 10
    $meter.Margin = '0,0,0,12'
    $content = @($head, $meter)

    if (Test-PASUIRunActive $status) {
        $content += New-PASUIText 'Running on its own: you can close this window and open it again later.' 'Hint' -Margin '0,0,0,14'
    } elseif ($status -eq 'Succeeded') {
        $health = New-PASUIButton 'act-health' 'Check the lab' 'Primary' -Margin '0,12,0,0'
        $health.HorizontalAlignment = 'Left'
        $content += New-PASUIBox 'ok' 'The lab is installed.' 'Check that every component is connected to the Vault before you use it.' -Content @($health)
    } elseif ($status -eq 'Abandoned') {
        $content += New-PASUIBox 'warn' 'This installation was stopped.' 'The servers keep what was installed until then.'
    } else {
        $failure = Get-PASUIFailure $run
        $text = [string]$run.Message
        $inner = @()
        if ($failure) {
            $text = 'It stopped at "' + (Get-PASUIStageText $failure.Stage) + '" of ' + [string]$failure.Component + '.'
            $inner += New-PASUIPre ([string]$failure.Message)
        }
        $inner += New-PASUIText 'Correct the cause on the server, then continue. Steps that are finished are not repeated.' -Brush 'TextSoft' -Margin '0,10,0,10'
        $actions = @()
        if ($failure) {
            $actions += New-PASUIButton 'act-retry' 'Try this step again' 'Primary' -Margin '0,0,10,6'
        }
        $actions += New-PASUIButton 'act-resume' 'Continue without repeating it' 'Btn' -Margin '0,0,10,6'
        $actions += New-PASUIButton 'act-diag' 'Save the logs as a ZIP' 'Btn' -Margin '0,0,10,6'
        $inner += New-PASUIRow $actions
        $content += New-PASUIBox 'bad' 'The installation stopped.' $text -Content $inner
    }
    if ($S.Health) {
        $content += New-PASUIHealthCard
    }
    Set-PASUIRegion 'RunStatus' $content
}

function Show-PASUIRunComponents {
    # One line per component: state, where, progress bar, current step. Several can be installing at once.
    $progress = Get-PASUIRunProgress -Snapshot $S.Run -Catalog $Catalog -PlanItems $S.RunPlan
    $active = Test-PASUIRunActive ([string]$S.Run.Status)
    $grid = New-PASUIGrid @('Auto', '2*', '3*', 'Auto')
    $number = 0
    foreach ($row in @($progress.Components)) {
        $now = Get-PASUIStatusText $row.Status
        if ($row.Kind -eq 'run' -and $row.Current) {
            $now = Get-PASUIStageText $row.Current
        } elseif ($row.Kind -eq 'bad' -and $row.Current) {
            $now = 'Stopped at: ' + (Get-PASUIStageText $row.Current)
            if ($active) {
                # The buttons to try again come when the run has ended: the other servers finish first.
                $now += '. The other servers go on; you can try this step again when they are finished.'
            }
        } elseif ($row.Kind -eq 'ok' -and [string]$row.Type -eq 'HTML5GW' -and $active) {
            # The gateway itself needs no Vault. Its entry in the PVWA configuration is made after PVWA and PSM.
            $now = 'Installed. It is entered into PVWA when PVWA and PSM are finished.'
        }
        if ($row.Checking -and $active) {
            $now = 'Checking what is already installed'
        }
        if ($row.GaveUp) {
            $now = 'Not continued: a server it depends on failed'
        }
        $waiting = ($row.Waiting -and $active)
        if ($waiting) {
            $now = [string]$row.Waiting
        }
        $sign = New-Object Windows.Controls.ContentControl
        $sign.Width = 16
        $sign.Height = 16
        $sign.Margin = '0,8,12,0'
        $sign.VerticalAlignment = 'Top'
        $sign.Focusable = $false
        if ($waiting) {
            $sign.Content = New-PASUIIcon 0xE823 'WarnFg' 14
        } elseif ($row.Kind -eq 'run' -and $active) {
            $sign.Content = New-PASUISpinner 'AccentFg' 14
        } elseif ($row.Kind -eq 'ok') {
            $sign.Content = New-PASUIIcon 0xE930 'OkFg' 14
        } elseif ($row.Kind -eq 'bad') {
            $sign.Content = New-PASUIIcon 0xE783 'BadFg' 14
        } else {
            $sign.Content = New-PASUIIcon 0xEA3A 'Muted' 14
        }
        $who = New-Object Windows.Controls.StackPanel
        $who.Margin = '0,5,14,5'
        $typeName = [string]$row.Type
        if ($script:PASUITypeNames.ContainsKey([string]$row.Type)) {
            $typeName = [string]$script:PASUITypeNames[[string]$row.Type]
        } elseif ([string]$row.Type -eq 'DomainJoin') {
            $typeName = 'Joining the domain'
        }
        Add-PASUIChild $who @((New-PASUIText $typeName -Bold), (New-PASUIText (([string]$row.Address + ' ' + [string]$row.Id).Trim()) 'Hint'))
        $prog = New-Object Windows.Controls.StackPanel
        $prog.Margin = '0,9,14,5'
        $meterKind = $row.Kind
        if ($waiting) {
            $meterKind = 'idle'
        }
        $nowText = New-PASUIText $now 'Hint' -Margin '0,4,0,0'
        Add-PASUIChild $prog @((New-PASUIMeter $row.Percent $meterKind 6), $nowText)
        $count = New-PASUIText "$($row.Done) / $($row.Total)" -Brush 'TextSoft' -Margin '0,6,0,0'
        $count.FontFamily = 'Consolas'
        Add-PASUICell $grid $sign $number 0
        Add-PASUICell $grid $who $number 1
        Add-PASUICell $grid $prog $number 2
        Add-PASUICell $grid $count $number 3
        $number++
    }
    Set-PASUIRegion 'RunComps' @($grid)
}

function Show-PASUIRunLog {
    # The newest 200 events, newest first, when the log is open; next to its title always the newest event.
    $events = @($S.Run.Events)
    $text = ''
    if ($events.Count) {
        $newest = $events[-1]
        $message = [string]$newest.Message
        if ($message.Length -gt 90) {
            $message = $message.Substring(0, 90) + '...'
        }
        $text = "$($events.Count) events, latest " + (Format-PASUITime ([string]$newest.TimestampUtc)) + ': ' + $message
    }
    if ($R.ContainsKey('RunLast')) {
        $R['RunLast'].Text = $text
    }
    if (-not $S.LogOpen) {
        Set-PASUIRegion 'RunLog'
        return
    }
    $shown = @($events | Select-Object -Last 200)
    [array]::Reverse($shown)
    $rows = @($shown | ForEach-Object {
            [pscustomobject]@{
                Kind = (Get-PASUIEventKind $_)
                Time = (Format-PASUITime ([string]$_.TimestampUtc))
                Component = [string]$_.Component
                Step = (Get-PASUIStageText ([string]$_.Stage))
                Message = [string]$_.Message
            }
        })
    $list = New-PASUIList 'LogRow' $rows
    $list.Margin = '0,8,0,2'
    Set-PASUIRegion 'RunLog' @($list)
}

function Show-PASUIRunAdvanced {
    # The PowerShell commands for this installation, and Stop. Only in the advanced view.
    if (-not $S.Advanced) {
        Set-PASUIRegion 'RunAdvanced'
        return
    }
    $id = [string]$S.Run.RunId
    $content = @(
        (New-PASUIText 'Follow, continue or stop this installation from a PowerShell prompt on this computer. It keeps running when the window is closed.' 'Hint' -Margin '0,0,0,6'),
        (New-PASUIPre ("Get-PASRun -RunId $id`nGet-PASRunEvent -RunId $id -Failed`nResume-PASRun -RunId $id`nStop-PASRun -RunId $id`nExport-PASDiagnostics -RunId $id -Path .\logs.zip"))
    )
    if (Test-PASUIRunActive ([string]$S.Run.Status)) {
        $stop = New-PASUIButton 'act-stop' 'Stop the installation' 'Danger' -Margin '0,12,0,0'
        $stop.HorizontalAlignment = 'Left'
        $content += $stop
    }
    Set-PASUIRegion 'RunAdvanced' @((New-PASUICard 'This installation from PowerShell' $content))
}

function New-PASUIHealthCard {
    # The result of "Check the lab": healthy or what is wrong, and one line per component.
    $health = $S.Health
    $content = @()
    if ($health.Healthy) {
        $content += New-PASUIBox 'ok' 'Healthy.' ([string]$health.Message)
    } else {
        $content += New-PASUIBox 'bad' 'Not healthy yet' '' @($health.Issues)
    }
    $rows = @($health.Components)
    if ($rows.Count) {
        $grid = New-PASUIGrid @('Auto', '2*', '2*', '*')
        $column = 0
        foreach ($header in @('', 'Component', 'Server', 'Version')) {
            Add-PASUICell $grid (New-PASUIText $header 'ColHead' -Margin '0,0,14,6') 0 $column
            $column++
        }
        $number = 0
        foreach ($row in $rows) {
            $number++
            $pill = New-PASUIPill 'not connected' 'bad'
            if ($row.LoggedOn) {
                $pill = New-PASUIPill 'connected' 'ok'
            }
            $pill.Margin = '0,4,14,4'
            Add-PASUICell $grid $pill $number 0
            Add-PASUICell $grid (New-PASUIText ([string]$row.User) -Margin '0,4,14,4') $number 1
            Add-PASUICell $grid (New-PASUIText ([string]$row.Address) -Brush 'TextSoft' -Margin '0,4,14,4') $number 2
            Add-PASUICell $grid (New-PASUIText ([string]$row.Version) -Brush 'TextSoft' -Margin '0,4,0,4') $number 3
        }
        $content += $grid
    }
    return New-PASUICard 'Lab check' $content
}
