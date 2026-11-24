# The building blocks of the desktop window: small functions that make one WPF control each, in the look of
# Window.xaml, and the helper that runs work away from the window's thread. Loaded by App.ps1 after the
# window exists; every function uses $window (styles and brushes) and nothing of the installer.
#
# A control that can be pressed or typed into carries its id in Tag. App.ps1 has one function per kind of
# event (Invoke-PASUIClick, Set-PASUIField, Set-PASUIToggle) that receives that id, so the scripted
# self-test can press the same buttons through UI Automation.

# One look per kind of message: icon, tone (icon and border) and tinted background. Text stays near-white.
$script:PASUITones = @{
    ok = @{ Fg = 'OkFg'; Bg = 'OkBg'; Line = 'OkLine'; Icon = 0xE930 }
    bad = @{ Fg = 'BadFg'; Bg = 'BadBg'; Line = 'BadLine'; Icon = 0xE783 }
    warn = @{ Fg = 'WarnFg'; Bg = 'WarnBg'; Line = 'WarnLine'; Icon = 0xE7BA }
    busy = @{ Fg = 'InfoFg'; Bg = 'InfoBg'; Line = 'InfoLine'; Icon = 0 }
    info = @{ Fg = 'InfoFg'; Bg = 'InfoBg'; Line = 'InfoLine'; Icon = 0xE946 }
}

function Get-PASUIBrush {
    param([string]$Key)
    return $window.Resources[$Key]
}

function Add-PASUIChild {
    # Adds controls to a panel. Returns nothing, so a page can be written as a list of calls.
    param($Panel, [object[]]$Children)
    foreach ($child in $Children) {
        if ($null -ne $child) {
            [void]$Panel.Children.Add($child)
        }
    }
}

function New-PASUIText {
    # A text block with the window's text colour, or the given style / brush key.
    param([string]$Text, [string]$Style = '', [switch]$Bold, [string]$Brush = '', [string]$Margin = '')
    $block = New-Object Windows.Controls.TextBlock
    $block.Text = $Text
    $block.TextWrapping = 'Wrap'
    if ($Style) {
        # The style decides the colour.
        $block.Style = $window.Resources[$Style]
    } else {
        $block.Foreground = Get-PASUIBrush 'Text'
    }
    if ($Brush) {
        $block.Foreground = Get-PASUIBrush $Brush
    }
    if ($Bold) {
        $block.FontWeight = [Windows.FontWeights]::SemiBold
    }
    if ($Margin) {
        $block.Margin = $Margin
    }
    return $block
}

function New-PASUIIcon {
    # A Segoe MDL2 Assets glyph in one of the palette colours.
    param([int]$Code, [string]$Brush, [double]$Size = 16)
    $icon = New-Object Windows.Controls.TextBlock
    $icon.Style = $window.Resources['Icon']
    $icon.Text = [string][char]$Code
    $icon.FontSize = $Size
    $icon.Foreground = Get-PASUIBrush $Brush
    return $icon
}

function New-PASUISpinner {
    # A turning three-quarter ring: the busy sign of boxes, of the message line and of a button.
    param([string]$Brush = 'InfoFg', [double]$Size = 16)
    $path = New-Object Windows.Shapes.Path
    $path.Data = [Windows.Media.Geometry]::Parse('M 8,1.5 A 6.5,6.5 0 1 1 1.5,8')
    $path.Stroke = Get-PASUIBrush $Brush
    $path.StrokeThickness = 2
    $path.StrokeStartLineCap = 'Round'
    $path.StrokeEndLineCap = 'Round'
    $path.Width = $Size
    $path.Height = $Size
    $path.Stretch = 'Uniform'
    $path.RenderTransformOrigin = '0.5,0.5'
    $rotate = New-Object Windows.Media.RotateTransform
    $path.RenderTransform = $rotate
    $spin = New-Object Windows.Media.Animation.DoubleAnimation(0, 360, (New-Object Windows.Duration([TimeSpan]::FromSeconds(0.9))))
    $spin.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $rotate.BeginAnimation([Windows.Media.RotateTransform]::AngleProperty, $spin)
    return $path
}

function New-PASUIToneIcon {
    param([string]$Kind, [double]$Size = 16)
    if ($Kind -eq 'busy') {
        return New-PASUISpinner $script:PASUITones[$Kind].Fg $Size
    }
    return New-PASUIIcon $script:PASUITones[$Kind].Icon $script:PASUITones[$Kind].Fg $Size
}

function New-PASUIBox {
    # A message box: Kind ok, bad, warn, busy or info; a bold title, a text, an optional list, and optional
    # further controls below (buttons, a text that can be copied). -Collapsed: the list is hidden behind a
    # "Show the list" button.
    param([string]$Kind, [string]$Title, [string]$Text = '', [string[]]$Items = @(), [object[]]$Content = @(), [switch]$Collapsed)
    $tone = $script:PASUITones[$Kind]
    $box = New-Object Windows.Controls.Border
    $box.Background = Get-PASUIBrush $tone.Bg
    $box.BorderBrush = Get-PASUIBrush $tone.Line
    $box.BorderThickness = '1'
    $box.CornerRadius = '10'
    $box.Padding = '16,14'
    $box.Margin = '0,0,0,14'
    $dock = New-Object Windows.Controls.DockPanel
    $icon = New-PASUIToneIcon $Kind 18
    $icon.Margin = '0,1,12,0'
    $icon.VerticalAlignment = 'Top'
    [Windows.Controls.DockPanel]::SetDock($icon, 'Left')
    [void]$dock.Children.Add($icon)
    $panel = New-Object Windows.Controls.StackPanel
    [void]$panel.Children.Add((New-PASUIText $Title -Bold))
    if ($Text) {
        [void]$panel.Children.Add((New-PASUIText $Text -Brush 'TextSoft' -Margin '0,3,0,0'))
    }
    $list = @($Items | Where-Object { $_ })
    if ($list.Count) {
        $lines = New-Object Windows.Controls.StackPanel
        $lines.Margin = '0,8,0,0'
        foreach ($item in $list) {
            $line = New-Object Windows.Controls.DockPanel
            $line.Margin = '0,3,0,0'
            $dot = New-Object Windows.Shapes.Ellipse
            $dot.Width = 5
            $dot.Height = 5
            $dot.Fill = Get-PASUIBrush $tone.Fg
            $dot.Margin = '2,7,10,0'
            $dot.VerticalAlignment = 'Top'
            [Windows.Controls.DockPanel]::SetDock($dot, 'Left')
            [void]$line.Children.Add($dot)
            [void]$line.Children.Add((New-PASUIText $item -Brush 'TextSoft'))
            [void]$lines.Children.Add($line)
        }
        if ($Collapsed) {
            $lines.Visibility = 'Collapsed'
            $toggle = New-Object Windows.Controls.Button
            $toggle.Style = $window.Resources['Ghost']
            $toggle.Content = 'Show the list'
            $toggle.Tag = $lines
            $toggle.Margin = '0,8,0,0'
            $toggle.HorizontalAlignment = 'Left'
            [Windows.Automation.AutomationProperties]::SetName($toggle, ('Show or hide the list: ' + $Title))
            $toggle.Add_Click({
                    param($sender, $eventArgs)
                    Invoke-PASUISafe {
                        if ([string]$sender.Tag.Visibility -eq 'Visible') {
                            $sender.Tag.Visibility = 'Collapsed'
                            $sender.Content = 'Show the list'
                        } else {
                            $sender.Tag.Visibility = 'Visible'
                            $sender.Content = 'Hide the list'
                        }
                    }
                })
            [void]$panel.Children.Add($toggle)
        }
        [void]$panel.Children.Add($lines)
    }
    Add-PASUIChild $panel $Content
    [void]$dock.Children.Add($panel)
    $box.Child = $dock
    [Windows.Automation.AutomationProperties]::SetName($box, ("$Title $Text " + ($list -join '; ')).Trim())
    return $box
}

function New-PASUICard {
    # A card with an optional heading. Returns the card; its content panel is $card.Child.
    param([string]$Title = '', [object[]]$Content = @(), [switch]$Flat)
    $card = New-Object Windows.Controls.Border
    $card.Style = $window.Resources['CardBox']
    if ($Flat) {
        $card.Padding = '0'
    }
    $panel = New-Object Windows.Controls.StackPanel
    if ($Title) {
        [void]$panel.Children.Add((New-PASUIText $Title 'H2'))
    }
    Add-PASUIChild $panel $Content
    $card.Child = $panel
    return $card
}

function New-PASUIRow {
    # Controls side by side, wrapping when the window is narrow.
    param([object[]]$Content = @(), [string]$Margin = '0')
    $row = New-Object Windows.Controls.WrapPanel
    $row.Margin = $Margin
    Add-PASUIChild $row $Content
    return $row
}

function New-PASUIButton {
    # A button that reports its id to Invoke-PASUIClick. Kind: a button style of Window.xaml.
    param([string]$Id, [string]$Text, [string]$Kind = 'Btn', [string]$Margin = '0,0,10,0', [string]$Label = '')
    $button = New-Object Windows.Controls.Button
    $button.Style = $window.Resources[$Kind]
    $button.Content = $Text
    $button.Tag = $Id
    $button.Margin = $Margin
    if (-not $Label) {
        $Label = $Text
    }
    [Windows.Automation.AutomationProperties]::SetName($button, $Label)
    $button.Add_Click({
            param($sender, $eventArgs)
            $id = [string]$sender.Tag
            Invoke-PASUISafe { Invoke-PASUIClick $id }
        })
    return $button
}

function New-PASUITextBox {
    # A text box that reports what is typed to Set-PASUIField under its id.
    param([string]$Id, [string]$Value = '', [string]$Label = '', [double]$Width = 0, [string]$Placeholder = '')
    $box = New-Object Windows.Controls.TextBox
    $box.Text = $Value
    $box.Tag = $Id
    if ($Width -gt 0) {
        $box.Width = $Width
        $box.HorizontalAlignment = 'Left'
    }
    if ($Placeholder) {
        $box.ToolTip = $Placeholder
    }
    if ($Label) {
        [Windows.Automation.AutomationProperties]::SetName($box, $Label)
    }
    $box.Add_TextChanged({
            param($sender, $eventArgs)
            Set-PASUIField ([string]$sender.Tag) ([string]$sender.Text)
        })
    return $box
}

function Get-PASUIPasswordBox {
    # The password box with this id. It is made once and used again when its page is drawn again, so what
    # was typed is still in it. The model only learns THAT a password was typed (Set-PASUIPasswordMark).
    param([string]$Id, [string]$Label)
    if ($PasswordBoxes.ContainsKey($Id)) {
        $box = $PasswordBoxes[$Id]
        if ($box.Parent -is [Windows.Controls.Panel]) {
            $box.Parent.Children.Remove($box)
        }
    } else {
        $box = New-Object Windows.Controls.PasswordBox
        $box.Tag = $Id
        $box.Add_PasswordChanged({
                param($sender, $eventArgs)
                Set-PASUIPasswordMark ([string]$sender.Tag) ([bool]$sender.SecurePassword.Length)
            })
        $PasswordBoxes[$Id] = $box
    }
    [Windows.Automation.AutomationProperties]::SetName($box, $Label)
    Set-PASUIPasswordMark $Id ([bool]$box.SecurePassword.Length)
    return $box
}

function Set-PASUIPasswordMark {
    # Tells the model that a password is typed (or not), never what it is.
    param([string]$Id, [bool]$Typed)
    $mark = ''
    if ($Typed) {
        $mark = 'set'
    }
    if ($Id -match '^srv-([a-z0-9]+)-pass$') {
        Set-PASUISlotValue $S $Matches[1] 'Password' $mark
        return
    }
    if ($Id -match '^sec-(\w+)$') {
        if ($Typed) {
            $S.Secrets[$Matches[1]] = $mark
        } else {
            $S.Secrets.Remove($Matches[1])
        }
    }
}

function New-PASUIField {
    # A label, a control and an optional hint, one under the other.
    param([string]$Label, $Control, [string]$Hint = '', [string]$Margin = '0,0,6,8')
    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = $Margin
    [void]$panel.Children.Add((New-PASUIText $Label 'Label'))
    [void]$panel.Children.Add($Control)
    if ($Hint) {
        [void]$panel.Children.Add((New-PASUIText $Hint 'Hint' -Margin '0,3,0,0'))
    }
    return $panel
}

function New-PASUICheck {
    # A check box that reports to Set-PASUIToggle under its id.
    param([string]$Id, [string]$Text, [bool]$Checked)
    $check = New-Object Windows.Controls.CheckBox
    $check.Style = $window.Resources['Check']
    $label = New-PASUIText $Text -Brush 'TextSoft'
    $check.Content = $label
    $check.IsChecked = $Checked
    $check.Tag = $Id
    [Windows.Automation.AutomationProperties]::SetName($check, $Text)
    # Checked and Unchecked, not Click: they also come when the box is switched through UI Automation.
    $changed = {
        param($sender, $eventArgs)
        $id = [string]$sender.Tag
        $checked = [bool]$sender.IsChecked
        Invoke-PASUISafe { Set-PASUIToggle $id $checked }
    }
    $check.Add_Checked($changed)
    $check.Add_Unchecked($changed)
    return $check
}

function New-PASUIPill {
    # A small rounded tag. Kind: ok, bad, run, warn or idle.
    param([string]$Text, [string]$Kind = 'idle')
    $pill = New-Object Windows.Controls.Border
    $pill.CornerRadius = '10'
    $pill.Padding = '9,1,9,2'
    $pill.HorizontalAlignment = 'Left'
    $pill.VerticalAlignment = 'Center'
    $pill.Background = Get-PASUIBrush 'CardAlt'
    $brush = 'TextSoft'
    switch ($Kind) {
        'ok' {
            $pill.Background = Get-PASUIBrush 'OkBg'
            $brush = 'OkFg'
        }
        'bad' {
            $pill.Background = Get-PASUIBrush 'BadBg'
            $brush = 'BadFg'
        }
        'run' {
            $pill.Background = Get-PASUIBrush 'AccentBg'
            $brush = 'AccentFg'
        }
        'warn' {
            $pill.Background = Get-PASUIBrush 'WarnBg'
            $brush = 'WarnFg'
        }
    }
    $label = New-PASUIText $Text -Brush $brush -Bold
    $label.FontSize = 11.5
    $label.TextWrapping = 'NoWrap'
    $pill.Child = $label
    return $pill
}

function New-PASUIMeter {
    # A progress bar. Kind: run (accent), ok, bad or idle.
    param([int]$Percent, [string]$Kind = 'run', [double]$Height = 8)
    $track = New-Object Windows.Controls.Grid
    $track.Height = $Height
    $back = New-Object Windows.Controls.Border
    $back.Background = Get-PASUIBrush 'CardAlt'
    $back.CornerRadius = [string]($Height / 2)
    [void]$track.Children.Add($back)
    $fill = New-Object Windows.Controls.Border
    $fill.CornerRadius = [string]($Height / 2)
    $fill.HorizontalAlignment = 'Left'
    $fill.Background = Get-PASUIBrush 'Accent'
    if ($Kind -eq 'ok') {
        $fill.Background = Get-PASUIBrush 'OkFg'
    } elseif ($Kind -eq 'bad') {
        $fill.Background = Get-PASUIBrush 'BadFg'
    } elseif ($Kind -eq 'idle') {
        $fill.Background = Get-PASUIBrush 'LineStrong'
    }
    # The width follows the track: two columns that share the space as Percent : rest.
    $share = [Math]::Max(0, [Math]::Min(100, $Percent))
    $first = New-Object Windows.Controls.ColumnDefinition
    $first.Width = New-Object Windows.GridLength($share, [Windows.GridUnitType]::Star)
    $second = New-Object Windows.Controls.ColumnDefinition
    $second.Width = New-Object Windows.GridLength((100 - $share), [Windows.GridUnitType]::Star)
    [void]$track.ColumnDefinitions.Add($first)
    [void]$track.ColumnDefinitions.Add($second)
    [Windows.Controls.Grid]::SetColumnSpan($back, 2)
    $fill.HorizontalAlignment = 'Stretch'
    [void]$track.Children.Add($fill)
    return $track
}

function New-PASUIChoice {
    # A card that can be chosen: title, what it means, an optional note and badge. Reports its id as a click.
    param([string]$Id, [string]$Title, [string]$What, [bool]$Selected, [string]$Note = '', [string]$Badge = '', [double]$Width = 196)
    $button = New-Object Windows.Controls.Button
    $button.Style = $window.Resources['Choice']
    $button.Width = $Width
    $panel = New-Object Windows.Controls.StackPanel
    $head = New-Object Windows.Controls.WrapPanel
    $name = New-PASUIText $Title -Bold
    $name.FontSize = 14
    $name.Margin = '0,0,8,0'
    [void]$head.Children.Add($name)
    if ($Badge) {
        [void]$head.Children.Add((New-PASUIPill $Badge 'run'))
    }
    [void]$panel.Children.Add($head)
    $text = New-PASUIText $What -Brush 'TextSoft' -Margin '0,5,0,0'
    $text.FontSize = 12.5
    [void]$panel.Children.Add($text)
    if ($Note) {
        [void]$panel.Children.Add((New-PASUIText $Note 'Hint' -Margin '0,6,0,0'))
    }
    $button.Content = $panel
    # The style shows Tag = 'selected'; the id is kept in Uid.
    $button.Uid = $Id
    if ($Selected) {
        $button.Tag = 'selected'
    }
    [Windows.Automation.AutomationProperties]::SetName($button, "$Title. $What")
    $button.Add_Click({
            param($sender, $eventArgs)
            $id = [string]$sender.Uid
            Invoke-PASUISafe { Invoke-PASUIClick $id }
        })
    return $button
}

function New-PASUIPre {
    # Text in a fixed-width font that can be selected and copied.
    param([string]$Text)
    $box = New-Object Windows.Controls.TextBox
    $box.Style = $window.Resources['Pre']
    $box.Text = $Text
    return $box
}

function New-PASUIGrid {
    # A grid with the given column widths: 'Auto', '*', '2*' or a number of pixels.
    param([string[]]$Columns)
    $grid = New-Object Windows.Controls.Grid
    foreach ($width in $Columns) {
        $column = New-Object Windows.Controls.ColumnDefinition
        if ($width -eq 'Auto') {
            $column.Width = [Windows.GridLength]::Auto
        } elseif ($width -match '^(\d*)\*$') {
            $stars = 1
            if ($Matches[1]) {
                $stars = [int]$Matches[1]
            }
            $column.Width = New-Object Windows.GridLength($stars, [Windows.GridUnitType]::Star)
        } else {
            $column.Width = New-Object Windows.GridLength([double]$width)
        }
        [void]$grid.ColumnDefinitions.Add($column)
    }
    return $grid
}

function Add-PASUICell {
    # Puts a control into a grid cell; rows are added as needed.
    param([Windows.Controls.Grid]$Grid, $Element, [int]$Row, [int]$Column, [int]$ColumnSpan = 1)
    while ($Grid.RowDefinitions.Count -le $Row) {
        $definition = New-Object Windows.Controls.RowDefinition
        $definition.Height = [Windows.GridLength]::Auto
        [void]$Grid.RowDefinitions.Add($definition)
    }
    [Windows.Controls.Grid]::SetRow($Element, $Row)
    [Windows.Controls.Grid]::SetColumn($Element, $Column)
    if ($ColumnSpan -gt 1) {
        [Windows.Controls.Grid]::SetColumnSpan($Element, $ColumnSpan)
    }
    [void]$Grid.Children.Add($Element)
}

function New-PASUIList {
    # A list filled from data with one of the row templates of Window.xaml (CheckRow, LogRow).
    param([string]$Template, [object[]]$Rows = @())
    $list = New-Object Windows.Controls.ItemsControl
    $list.ItemTemplate = $window.Resources[$Template]
    $list.AlternationCount = 2
    $list.Focusable = $false
    $list.ItemsSource = @($Rows)
    return $list
}

function Get-PASUIShownText {
    # Every text below a control, joined with spaces: what a person would read there. For the self-test
    # and for nothing else. Lists filled from data are read from their rows.
    param($Element)
    if ($null -eq $Element) {
        return ''
    }
    $parts = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Element)
    while ($queue.Count) {
        $node = $queue.Dequeue()
        if ($node -is [string]) {
            [void]$parts.Add($node)
            continue
        }
        if ($node -is [Windows.UIElement] -and $node.Visibility -ne 'Visible') {
            continue
        }
        if ($node -is [Windows.Controls.TextBlock]) {
            # An icon is a glyph of the symbol font, not text.
            if ([string]$node.FontFamily.Source -ne 'Segoe MDL2 Assets') {
                [void]$parts.Add([string]$node.Text)
            }
            continue
        }
        if ($node -is [Windows.Controls.TextBox]) {
            [void]$parts.Add([string]$node.Text)
            continue
        }
        if ($node -is [Windows.Controls.ItemsControl] -and $node.ItemsSource) {
            foreach ($row in @($node.ItemsSource)) {
                [void]$parts.Add((@($row.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join ' '))
            }
            continue
        }
        if ($node -is [Windows.DependencyObject]) {
            foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($node)) {
                $queue.Enqueue($child)
            }
        }
    }
    return (@($parts | Where-Object { $_ }) -join ' ')
}

function Find-PASUIControl {
    # The visible control with this id below a control (Tag, or Uid for a choice card), or $null.
    param($Root, [string]$Id)
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($Root)
    while ($queue.Count) {
        $node = $queue.Dequeue()
        if ($node -isnot [Windows.DependencyObject]) {
            continue
        }
        if ($node -is [Windows.UIElement] -and $node.Visibility -ne 'Visible') {
            continue
        }
        if ($node -is [Windows.FrameworkElement] -and ([string]$node.Tag -eq $Id -or [string]$node.Uid -eq $Id)) {
            return $node
        }
        foreach ($child in [Windows.LogicalTreeHelper]::GetChildren($node)) {
            $queue.Enqueue($child)
        }
    }
    return $null
}

# ------------------------------------------------------------------ work away from the window's thread

# Runs a script block in another runspace and brings the result back to the window's thread: runspaces from
# a pool, and one timer of the window that collects the finished ones and calls their callbacks. So every
# callback runs on the window's thread, in the scope of App.ps1.
$script:PASUIPool = [runspacefactory]::CreateRunspacePool(1, 3)
$script:PASUIPool.Open()
$script:PASUITasks = New-Object System.Collections.ArrayList
# Number of pieces of work that were started and whose callback has not finished yet.
$script:PASUIPending = 0
$script:PASUITaskTimer = New-Object Windows.Threading.DispatcherTimer
$script:PASUITaskTimer.Interval = [TimeSpan]::FromMilliseconds(100)

function Start-PASUITask {
    <# Runs -ScriptBlock away from the window's thread and then calls -OnCompleted with its output (an array),
       or -OnFailed with the exception, on the window's thread. The script block runs in a runspace that has
       the backend commands of this window (the contract is loaded there first); it gets -ArgumentList as its
       parameters and sees no variable of the window. #>
    param([scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [scriptblock]$OnCompleted = $null, [scriptblock]$OnFailed = $null)
    $script:PASUIPending++
    $shell = [powershell]::Create()
    $shell.RunspacePool = $script:PASUIPool
    # Only the text of the script block crosses over: it runs in the other runspace, with its arguments.
    [void]$shell.AddScript({
            param([string]$ContractPath, [string]$Kind, [string]$Body, [object[]]$Arguments)
            $ErrorActionPreference = 'Stop'
            . $ContractPath
            $null = Import-PASUIBackend -Kind $Kind
            & ([scriptblock]::Create($Body)) @Arguments
        }.ToString())
    [void]$shell.AddArgument((Join-Path (Join-Path $PSScriptRoot 'Backend') 'Backend.Contract.ps1'))
    [void]$shell.AddArgument([string]$S.Backend)
    [void]$shell.AddArgument($ScriptBlock.ToString())
    [void]$shell.AddArgument($ArgumentList)
    [void]$script:PASUITasks.Add(@{ Shell = $shell; Handle = $shell.BeginInvoke(); OnCompleted = $OnCompleted; OnFailed = $OnFailed })
    $script:PASUITaskTimer.Start()
}

function Complete-PASUITask {
    # Calls the callback of a finished piece of work. An error in a callback becomes the red message line.
    param([hashtable]$Task, $Result, $Failure)
    try {
        Invoke-PASUISafe {
            if ($Failure) {
                if ($Task.OnFailed) {
                    & $Task.OnFailed $Failure
                } else {
                    throw $Failure
                }
            } elseif ($Task.OnCompleted) {
                & $Task.OnCompleted $Result
            }
        }
    } finally {
        $script:PASUIPending--
    }
}

$script:PASUITaskTimer.Add_Tick({
        foreach ($task in @($script:PASUITasks)) {
            if (-not $task.Handle.IsCompleted) {
                continue
            }
            [void]$script:PASUITasks.Remove($task)
            $failure = $null
            $result = $null
            try {
                $result = @($task.Shell.EndInvoke($task.Handle))
            } catch {
                $failure = $_.Exception.GetBaseException()
            } finally {
                $task.Shell.Dispose()
            }
            Complete-PASUITask $task $result $failure
        }
        if (-not $script:PASUITasks.Count) {
            $script:PASUITaskTimer.Stop()
        }
    })

function Stop-PASUITasks {
    # The window is closing: nothing is collected any more.
    $script:PASUITaskTimer.Stop()
    try {
        $script:PASUIPool.Close()
        $script:PASUIPool.Dispose()
    } catch {
        $null = $_
    }
}

function Wait-PASUIPump {
    # Lets the window work for a while from inside a function that runs on the window's thread (the self-test).
    param([int]$Milliseconds = 100)
    $script:PASUIPumpFrame = New-Object Windows.Threading.DispatcherFrame
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $timer.Add_Tick({
            param($sender, $eventArgs)
            $sender.Stop()
            $script:PASUIPumpFrame.Continue = $false
        })
    $timer.Start()
    [Windows.Threading.Dispatcher]::PushFrame($script:PASUIPumpFrame)
}
