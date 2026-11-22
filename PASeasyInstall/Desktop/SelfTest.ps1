# Scripted walk through the desktop window, for automated tests. Loaded by App.ps1 only with -SelfTest.
#
# The walk does what a user does, in that order: it presses the buttons of the window through UI Automation
# (so a button that is missing, hidden or disabled fails the walk), types into the fields, and checks what
# the window shows after each step. Between the steps the window keeps working (Wait-PASUIPump), exactly as
# it does for a person. It needs no desktop session: it also runs in an SSH session, against the Mock
# backend and against real servers.
#
# Scenario file (JSON):
#   media            folder with the installer media
#   dropMedia        true: the media folder is dropped on the window instead of typed
#   labFile          a saved lab file: it is opened first, as "Open a saved lab file" does, and the walk goes on
#                    from the Media step with the choices of that file (preset, counts and domain are then left out)
#   labName          name of the lab (Mock backend: a name with "fail" makes the first install step fail)
#   preset           starter | standard | full | custom
#   existingVault    address of an existing Vault (preset custom: components are added to it)
#   domain           { "mode": "New" or "Existing", "name": "pam.lab" }; its form line is servers.dc or servers.domain
#   counts           preset custom: { "PVWA": 1, "CPM": 0, "PSM": 0, "PSMP": 1, "HTML5GW": 0, "PTA": 0 }
#   advanced         true: switch Advanced on at the Servers step and keep it on
#   servers          { "<slot key>": { "name": "...", "address": "..." } }; slot keys as in Get-PASUIServerSlots.
#                    Left out: made-up addresses 192.0.2.x (Mock backend only)
#   servers.<key>.password   a password for that one server (default: the walk's password)
#   expectServerProblem  a pattern: the server check must fail and show it; the walk ends there
#   stopAfter        'review': end the walk on the review step, install nothing
#                    'stopped': press "Stop the installation" (Advanced) while it runs, check that it stopped, end
#   timeoutMinutes   how long to wait for the installation (default 5)
#   openRun          a run id: only open that installation from the start page and check the lab
#   retryAfterFailure  true: when the installation stops with an error, press "Try this step again" at once
#   continueFile     when the installation stops with an error: wait until this file exists (somebody
#                    corrected the cause), then press "Try this step again". Left out: an error ends the walk
#   forgetAccounts   true: before the lab check the window forgets the accounts, as if it had been closed and
#                    opened again, so the accounts dialog is walked too
#   log              file that receives the PASS / FAIL lines as well
#   snapshots        folder that receives every screen as a PNG file
# One password is used for every account and Vault password of the walk. It comes from
# $env:PASEASY_LAB_PASSWORD and is never written anywhere.

function Write-PASUITestLine {
    param([string]$Text)
    [Console]::Out.WriteLine($Text)
    if ($script:PASUITest.Log) {
        Add-Content -LiteralPath $script:PASUITest.Log -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $Text) -Encoding UTF8
    }
}

function Wait-PASUITestIdle {
    # Lets the window work until nothing it started in the background is still under way.
    param([int]$Seconds = 300)
    $deadline = [datetime]::UtcNow.AddSeconds($Seconds)
    Wait-PASUIPump 60
    while ($script:PASUIPending -gt 0 -and [datetime]::UtcNow -lt $deadline) {
        Wait-PASUIPump 100
    }
    if ($script:PASUIPending -gt 0) {
        throw "The window was still working after $Seconds seconds"
    }
}

function Get-PASUITestRegion {
    # A part of the window by name: view (the page), notice, dialog, or a part of the page (see $R).
    param([string]$Name)
    switch ($Name) {
        'view' { return $ui.PageHost }
        'notice' { return $ui.Notice }
        'dialog' { return $ui.Overlay }
        'bar' { return $ui.Bar }
    }
    if ($R.ContainsKey($Name)) {
        return $R[$Name]
    }
    return $null
}

function Assert-PASUIShown {
    # The text shown in a part of the window must match a pattern (case-sensitive).
    param([string]$Region, [string]$Pattern, [string]$What)
    $text = Get-PASUIShownText (Get-PASUITestRegion $Region)
    if ($text -cmatch $Pattern) {
        Write-PASUITestLine "PASS $What"
        return
    }
    $script:PASUITest.Failures++
    Write-PASUITestLine ("FAIL $What :: expected /$Pattern/ in: " + $text.Substring(0, [Math]::Min(400, $text.Length)))
}

function Assert-PASUITest {
    param([bool]$Passed, [string]$What)
    if ($Passed) {
        Write-PASUITestLine "PASS $What"
        return
    }
    $script:PASUITest.Failures++
    Write-PASUITestLine "FAIL $What"
}

function Invoke-PASUITestClick {
    # Presses the button (or check box) with this id the way a screen reader does: through UI Automation.
    # It must be on screen and enabled. Then the window works until it is idle again.
    param([string]$Id, [switch]$NoWait)
    $control = Find-PASUIControl $ui.Shell $Id
    if (-not $control) {
        throw "There is no control '$Id' on screen"
    }
    if (-not $control.IsEnabled) {
        throw "The control '$Id' is disabled"
    }
    if ($control -is [Windows.Controls.CheckBox]) {
        $peer = New-Object Windows.Automation.Peers.CheckBoxAutomationPeer($control)
        $peer.GetPattern([Windows.Automation.Peers.PatternInterface]::Toggle).Toggle()
    } else {
        $peer = New-Object Windows.Automation.Peers.ButtonAutomationPeer($control)
        $peer.GetPattern([Windows.Automation.Peers.PatternInterface]::Invoke).Invoke()
    }
    if ($NoWait) {
        Wait-PASUIPump 60
        return
    }
    Wait-PASUITestIdle
}

function Set-PASUITestField {
    # Types into the text box with this id.
    param([string]$Id, [string]$Value)
    $control = Find-PASUIControl $ui.Shell $Id
    if ($control -isnot [Windows.Controls.TextBox]) {
        throw "There is no text box '$Id' on screen"
    }
    $control.Text = $Value
}

function Set-PASUITestPassword {
    # Types into the password box with this id.
    param([string]$Id, [string]$Value)
    $control = Find-PASUIControl $ui.Shell $Id
    if ($control -isnot [Windows.Controls.PasswordBox]) {
        throw "There is no password box '$Id' on screen"
    }
    $control.Password = $Value
}

function Save-PASUISnapshot {
    # Keeps what the window shows now as a PNG file. -Bottom: scrolled to the end of the page first.
    param([string]$Name, [switch]$Bottom)
    $test = $script:PASUITest
    if (-not $test.Snapshots) {
        return
    }
    if ($Bottom) {
        $ui.Page.ScrollToEnd()
    }
    Wait-PASUIPump 80
    $window.UpdateLayout()
    $root = $ui.Shell
    $bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$root.ActualWidth, [int]$root.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($root)
    $encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create((Join-Path $test.Snapshots ($Name + '.png')))
    try {
        $encoder.Save($stream)
    } finally {
        $stream.Dispose()
    }
}

function Wait-PASUITestRun {
    # Follows the installation on its page until it is no longer running.
    param([int]$Minutes)
    $deadline = [datetime]::UtcNow.AddMinutes($Minutes)
    $pause = 400
    if ($Minutes -gt 10) {
        $pause = 5000
    }
    $lastLine = ''
    while ((Test-PASUIRunWatched) -and [datetime]::UtcNow -lt $deadline) {
        Wait-PASUIPump $pause
        Update-PASUIRun
        Wait-PASUITestIdle
        $line = [string]$S.Run.CurrentComponent + ' ' + [string]$S.Run.LastStep
        if ($line -ne $lastLine -and $Minutes -gt 10) {
            $lastLine = $line
            Write-PASUITestLine "INFO installing: $line"
        }
    }
}

function Submit-PASUITestAccounts {
    # What the accounts dialog needs from the user: every password, then Continue.
    # Nothing to do when the window still had the accounts and went on at once.
    param([string]$Password)
    if ($ui.Overlay.Visibility -ne 'Visible') {
        Wait-PASUITestIdle
        return
    }
    foreach ($box in @($DialogBoxes)) {
        $box.Password = $Password
    }
    Invoke-PASUITestClick 'dlg-yes'
}

function Invoke-PASUISelfTest {
    # Walks the scenario and returns the number of failed checks.
    param([string]$ScenarioPath)
    $script:PASUITest = @{ Failures = 0; Log = ''; Snapshots = ''; Ticks = 0 }
    # A tick of the window's thread every 100 ms: it stops when the window does not react.
    $heartbeat = New-Object Windows.Threading.DispatcherTimer
    $heartbeat.Interval = [TimeSpan]::FromMilliseconds(100)
    $heartbeat.Add_Tick({ $script:PASUITest.Ticks++ })
    $heartbeat.Start()
    try {
        $scenario = Get-Content -LiteralPath $ScenarioPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @('Log', 'Snapshots')) {
            $property = $scenario.PSObject.Properties[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)]
            if ($property -and [string]$property.Value) {
                $script:PASUITest[$name] = [string]$property.Value
            }
        }
        if ($script:PASUITest.Snapshots -and -not (Test-Path -LiteralPath $script:PASUITest.Snapshots)) {
            $null = New-Item -ItemType Directory -Path $script:PASUITest.Snapshots -Force
        }
        Wait-PASUITestIdle
        Invoke-PASUITestWalk $scenario
    } catch {
        $script:PASUITest.Failures++
        Write-PASUITestLine ('FAIL the walk stopped: ' + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace)
        try {
            Save-PASUISnapshot 'stopped-here'
        } catch {
            $null = $_
        }
    } finally {
        $heartbeat.Stop()
    }
    Write-PASUITestLine "SELFTEST failures=$($script:PASUITest.Failures)"
    return [int]$script:PASUITest.Failures
}

function Invoke-PASUITestWalk {
    param($Scenario)
    $password = [string]$env:PASEASY_LAB_PASSWORD
    if (-not $password) {
        $password = 'SelfTest-Password-1'
    }
    $labName = [string]$Scenario.labName
    $timeout = 5
    if ($Scenario.PSObject.Properties['timeoutMinutes']) {
        $timeout = [int]$Scenario.timeoutMinutes
    }
    $advanced = ($Scenario.PSObject.Properties['advanced'] -and [bool]$Scenario.advanced)

    Assert-PASUIShown 'view' 'Build a CyberArk PAM lab' 'start page'
    Assert-PASUITest ($ui.OptAdvanced.Visibility -ne 'Visible') 'no Advanced switch on the start page'
    Assert-PASUITest (($ui.SimBadge.Visibility -eq 'Visible') -eq ([string]$S.Backend -eq 'Mock')) 'the Simulation badge is shown only with the simulated installer'
    Save-PASUISnapshot '1-start'
    if ($Scenario.PSObject.Properties['openRun']) {
        # Short walk: open an installation from the list on the start page and check the lab.
        $runId = [string]$Scenario.openRun
        Invoke-PASUITestClick "run-$runId"
        Assert-PASUIShown 'RunStatus' 'The lab is installed' 'an earlier installation opens from the list'
        Invoke-PASUITestClick 'act-health'
        Submit-PASUITestAccounts $password
        Assert-PASUIShown 'RunStatus' 'Healthy\.' 'lab check'
        Save-PASUISnapshot '8-lab-checked'
        return
    }

    $fromFile = [bool]$Scenario.PSObject.Properties['labFile']
    if ($fromFile) {
        # What "Open a saved lab file" does once the file is chosen.
        Open-PASUILabFile ([string]$Scenario.labFile)
        Wait-PASUITestIdle
        Assert-PASUIShown 'notice' 'Lab file opened' 'a saved lab file opens'
        $labName = [string]$S.LabName
    } else {
        Invoke-PASUITestClick 'act-new'
    }
    Assert-PASUIShown 'view' 'Where is the installer media' 'media step'
    if ($Scenario.PSObject.Properties['dropMedia'] -and [bool]$Scenario.dropMedia) {
        # What a drop from Explorer does.
        Add-PASUIDroppedMedia @([string]$Scenario.media)
        Wait-PASUITestIdle
        Assert-PASUITest ([string]$S.MediaPath -eq [string]$Scenario.media) 'a dropped folder becomes the media folder'
    } else {
        Set-PASUITestField 'f-mediapath' ([string]$Scenario.media)
        Invoke-PASUITestClick 'act-scan'
    }
    Assert-PASUIShown 'MediaResult' 'PVWA' 'media found'
    Save-PASUISnapshot '2-media'

    Invoke-PASUITestClick 'act-next'
    Assert-PASUIShown 'view' 'What do you want to build' 'lab step'
    if ($fromFile) {
        Assert-PASUITest ([string]$S.Preset -eq 'custom') 'the lab of the file is shown as a Custom lab'
    } else {
        Invoke-PASUITestClick ('preset-' + [string]$Scenario.preset)
        Assert-PASUITest (($ui.OptAdvanced.Visibility -eq 'Visible') -eq ([string]$Scenario.preset -eq 'custom')) 'the Advanced switch is on the Lab step only for the Custom lab'
    }
    $existing = ''
    if ($Scenario.PSObject.Properties['existingVault']) {
        $existing = [string]$Scenario.existingVault
    }
    if ($existing) {
        Invoke-PASUITestClick 'vault-Existing'
        Assert-PASUIShown 'view' 'A Vault I already have' 'custom lab'
    }
    if ($Scenario.PSObject.Properties['counts']) {
        foreach ($type in $script:PASUIComponentTypes) {
            if (-not $Scenario.counts.PSObject.Properties[$type]) {
                continue
            }
            $wanted = [int]$Scenario.counts.PSObject.Properties[$type].Value
            while ([int]$S.Counts[$type] -lt $wanted) {
                Invoke-PASUITestClick "cnt-$type-inc"
            }
            while ([int]$S.Counts[$type] -gt $wanted) {
                Invoke-PASUITestClick "cnt-$type-dec"
            }
        }
    }
    if ($Scenario.PSObject.Properties['domain']) {
        Invoke-PASUITestClick ('domain-' + [string]$Scenario.domain.mode)
        Assert-PASUIShown 'view' 'DNS name of the domain' 'domain chosen'
        Set-PASUITestField 'f-domainname' ([string]$Scenario.domain.name)
    }
    if (-not $fromFile) {
        Set-PASUITestField 'f-labname' $labName
    }
    Save-PASUISnapshot '3-lab'
    Save-PASUISnapshot '3-lab-bottom' -Bottom

    Invoke-PASUITestClick 'act-next'
    Assert-PASUIShown 'view' 'Which servers' 'servers step'
    Invoke-PASUITestClick 'act-next'
    Assert-PASUIShown 'ServersIssues' 'Enter the (address|password)' 'missing entries are listed'
    if ($advanced) {
        Invoke-PASUITestClick 'opt-advanced'
        Assert-PASUIShown 'view' 'Address of this computer' 'the advanced view shows the network card'
    }
    if ($existing) {
        Set-PASUITestField 'f-existing' $existing
    }
    $number = 10
    foreach ($slot in Get-PASUIServerSlots $S) {
        $number++
        $address = "192.0.2.$number"
        if ($fromFile) {
            # The addresses of the file are in the form already.
            $address = Get-PASUISlotValue $S $slot 'Address'
            Assert-PASUITest ([bool]$address) "the lab file filled in the address of the $($slot.Roles) server"
        }
        $entry = $null
        if ($Scenario.PSObject.Properties['servers'] -and $Scenario.servers.PSObject.Properties[$slot.Key]) {
            $entry = $Scenario.servers.PSObject.Properties[$slot.Key].Value
            $address = [string]$entry.address
        }
        Set-PASUITestField "srv-$($slot.Key)-addr" $address
        if ($entry -and $entry.PSObject.Properties['name'] -and $slot.Named) {
            Set-PASUITestField "srv-$($slot.Key)-name" ([string]$entry.name)
        }
    }
    foreach ($slot in Get-PASUIServerSlots $S) {
        $slotPassword = $password
        if ($Scenario.PSObject.Properties['servers'] -and $Scenario.servers.PSObject.Properties[$slot.Key] -and
            $Scenario.servers.PSObject.Properties[$slot.Key].Value.PSObject.Properties['password']) {
            $slotPassword = [string]$Scenario.servers.PSObject.Properties[$slot.Key].Value.password
        }
        Set-PASUITestPassword "srv-$($slot.Key)-pass" $slotPassword
    }
    foreach ($field in Get-PASUIVaultSecrets $S) {
        Set-PASUITestPassword "sec-$($field.Key)" $password
    }
    if ([int]$S.Counts.PSMP -gt 0 -or [int]$S.Counts['HTML5GW'] -gt 0 -or [int]$S.Counts['PTA'] -gt 0) {
        Invoke-PASUITestClick 'f-eula'
        Assert-PASUITest ([bool]$S.AcceptEula) 'the license agreement of the Linux installers is accepted'
    }
    Save-PASUISnapshot '4-servers'
    Save-PASUISnapshot '4-servers-bottom' -Bottom
    $typed = (@($S.Slots.Values | ForEach-Object { [string]$_['Password'] }) + @($S.Secrets.Values | ForEach-Object { [string]$_ })) | Where-Object { $_ -and $_ -ne 'set' }
    Assert-PASUITest (-not @($typed).Count) 'the window keeps no typed password as text'

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $ticks = $script:PASUITest.Ticks
    Invoke-PASUITestClick 'act-next' -NoWait
    # The click must end at once, with the window saying that it checks the servers.
    Write-PASUITestLine ("INFO the click on Next returned after {0:N0} ms" -f $watch.Elapsed.TotalMilliseconds)
    Assert-PASUITest ([bool]$S.Checking -or [bool]$S.Preflight -or $S.Screen -eq 'review') 'the window says at once that it checks the servers'
    if ($S.Checking) {
        Assert-PASUIShown 'notice' 'Checking the servers' 'the message line names the server check'
        Assert-PASUITest (-not $ui.BtnNext.IsEnabled) 'Next is disabled while the servers are checked'
        Save-PASUISnapshot '4-servers-checking' -Bottom
    }
    Wait-PASUITestIdle 900
    $seconds = [Math]::Max(0.1, $watch.Elapsed.TotalSeconds)
    $perSecond = ($script:PASUITest.Ticks - $ticks) / $seconds
    Write-PASUITestLine ("INFO the server check took {0:N1} seconds; the window's thread ticked {1:N1} times a second meanwhile" -f $seconds, $perSecond)
    Assert-PASUITest ($perSecond -ge 3) 'the window kept reacting while the servers were checked'
    if ($Scenario.PSObject.Properties['expectServerProblem']) {
        # The walk ends here: the check must refuse to go on and say why.
        Assert-PASUIShown 'view' 'Which servers' 'the window stays on the servers step'
        Assert-PASUIShown 'PreflightResult' ([string]$Scenario.expectServerProblem) 'the server problem is shown'
        Save-PASUISnapshot '4-servers-problem' -Bottom
        return
    }
    if ($S.Screen -ne 'review') {
        Write-PASUITestLine ('INFO server check result: ' + (Get-PASUIShownText (Get-PASUITestRegion 'PreflightResult')) + ' | ' + (Get-PASUIShownText $ui.Notice) + ' | ' + (Get-PASUIShownText (Get-PASUITestRegion 'ServersIssues')))
    }
    Assert-PASUIShown 'view' 'Review and install' 'server check passed, review step'
    if ($Scenario.PSObject.Properties['stopAfter'] -and [string]$Scenario.stopAfter -eq 'review') {
        Save-PASUISnapshot '5-review'
        return
    }
    Assert-PASUIShown 'view' 'Install the lab' 'the plan is valid and can be installed'
    if ($advanced) {
        Assert-PASUIShown 'view' 'New-PASLabConfiguration' 'the advanced view shows the same from PowerShell'
    }
    Save-PASUISnapshot '5-review'

    Invoke-PASUITestClick 'act-install'
    Assert-PASUIShown 'dialog' 'Install the lab\?' 'Install asks before it starts'
    Save-PASUISnapshot '5-review-confirm'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Invoke-PASUITestClick 'dlg-yes' -NoWait
    Write-PASUITestLine ("INFO the window was free again {0:N1} seconds after Install" -f $watch.Elapsed.TotalSeconds)
    Wait-PASUITestIdle 600
    Write-PASUITestLine ("INFO the installation was started after {0:N0} seconds" -f $watch.Elapsed.TotalSeconds)
    Assert-PASUIShown 'view' ([regex]::Escape($labName)) 'run page'
    $kept = @($PasswordBoxes.Values | Where-Object { $_.SecurePassword.Length }).Count + $S.Secrets.Count + @($S.Slots.Values | Where-Object { $_.ContainsKey('Password') }).Count
    Assert-PASUITest (-not $kept) 'no typed password is kept after the installation started'
    Write-PASUITestLine "INFO run id $($S.RunId)"
    Wait-PASUIPump 1200
    Update-PASUIRun
    Wait-PASUITestIdle
    if (-not $S.LogOpen) {
        Invoke-PASUITestClick 'act-log'
    }
    Assert-PASUITest ($R['RunLog'].Children.Count -gt 0) 'the activity log opens'
    Save-PASUISnapshot '6-run-installing'
    if ($Scenario.PSObject.Properties['stopAfter'] -and [string]$Scenario.stopAfter -eq 'stopped') {
        Invoke-PASUITestClick 'act-stop'
        Assert-PASUIShown 'dialog' 'Stop the installation\?' 'Stop asks before it stops'
        Invoke-PASUITestClick 'dlg-yes'
        Wait-PASUIPump 500
        Update-PASUIRun
        Wait-PASUITestIdle
        Assert-PASUIShown 'RunStatus' 'This installation was stopped' 'the installation stops when asked'
        Save-PASUISnapshot '6-run-stopped-by-user'
        return
    }
    Wait-PASUITestRun -Minutes $timeout

    $round = 0
    $retry = ($Scenario.PSObject.Properties['retryAfterFailure'] -and [bool]$Scenario.retryAfterFailure)
    while ([string]$S.Run.Status -ne 'Succeeded' -and ($retry -or $Scenario.PSObject.Properties['continueFile']) -and $round -lt 3) {
        $round++
        Assert-PASUIShown 'RunStatus' 'The installation stopped' "the error is shown (stop $round)"
        Save-PASUISnapshot "6-run-stopped-$round"
        $failure = Get-PASUIFailure $S.Run
        if ($failure) {
            Write-PASUITestLine ("INFO stopped at $($failure.RetryStep): " + $failure.Message.Substring(0, [Math]::Min(300, $failure.Message.Length)))
        } else {
            Write-PASUITestLine ('INFO stopped: ' + [string]$S.Run.Message)
        }
        if (-not $retry) {
            $flag = [string]$Scenario.continueFile
            $deadline = [datetime]::UtcNow.AddMinutes(30)
            while (-not (Test-Path -LiteralPath $flag) -and [datetime]::UtcNow -lt $deadline) {
                Wait-PASUIPump 3000
            }
            if (-not (Test-Path -LiteralPath $flag)) {
                throw 'Nobody corrected the cause within 30 minutes'
            }
            Remove-Item -LiteralPath $flag -Force
        }
        if ($failure) {
            Invoke-PASUITestClick 'act-retry'
        } else {
            Invoke-PASUITestClick 'act-resume'
        }
        Submit-PASUITestAccounts $password
        Write-PASUITestLine 'INFO continued from the window'
        Wait-PASUITestRun -Minutes $timeout
    }

    Assert-PASUIShown 'RunStatus' 'The lab is installed' 'run finished'
    Save-PASUISnapshot '7-run-finished'
    if ($Scenario.PSObject.Properties['forgetAccounts'] -and [bool]$Scenario.forgetAccounts) {
        $S.Kept = $null
        $S.Configuration = $null
    }
    Invoke-PASUITestClick 'act-health'
    if ($ui.Overlay.Visibility -eq 'Visible') {
        Assert-PASUIShown 'dialog' 'Check the lab' 'the accounts dialog asks for the Vault password'
        Save-PASUISnapshot '8-accounts-dialog'
    } elseif ($Scenario.PSObject.Properties['forgetAccounts'] -and [bool]$Scenario.forgetAccounts) {
        Assert-PASUITest $false 'the accounts dialog is shown when the window forgot the accounts'
    }
    Submit-PASUITestAccounts $password
    Assert-PASUIShown 'RunStatus' 'Healthy\.' 'lab check'
    Save-PASUISnapshot '8-lab-checked'
    if ($advanced) {
        Assert-PASUIShown 'RunAdvanced' 'Resume-PASRun' 'the advanced view shows the commands of this installation'
        Save-PASUISnapshot '8-lab-checked-bottom' -Bottom
    }

    $runId = [string]$S.RunId
    Invoke-PASUITestClick 'nav-home'
    Assert-PASUIShown 'view' ([regex]::Escape($labName)) 'start page lists the installation'
    Save-PASUISnapshot '9-start-with-installation'
    Invoke-PASUITestClick "run-$runId"
    Assert-PASUIShown 'RunStatus' 'The lab is installed' 'the installation can be opened again from the list'
}
