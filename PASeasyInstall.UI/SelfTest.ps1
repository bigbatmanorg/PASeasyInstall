# Scripted walk through the desktop window, for automated tests. Loaded by App.ps1 only with -SelfTest.
#
# The walk calls the same functions the buttons and fields call, in the order a user would, and checks
# what the window shows after each step. It works headless (NATIVEHTMLKIT_TEST_MODE=1) and with a real
# window, against the Mock backend and against real servers.
#
# Scenario file (JSON):
#   media            folder with the installer media
#   labName          name of the lab
#   preset           starter | standard | full | custom
#   existingVault    address of an existing Vault (preset custom: components are added to it)
#   servers          { "<slot key>": { "name": "...", "address": "..." } }; slot keys as in Get-PASUIServerSlots.
#                    Left out: made-up addresses 192.0.2.x (Mock backend only)
#   timeoutMinutes   how long to wait for the installation (default 5)
#   continueFile     when the installation stops with an error: wait until this file exists (somebody
#                    corrected the cause), then press "Try this step again". Left out: an error ends the walk
#   log              file that receives the PASS / FAIL lines as well
#   snapshots        folder that receives every screen as an HTML file
#   screenshotScript script called with -Path <png> at every screen (real window only)
# The lab password comes from $env:PASEASY_LAB_PASSWORD and is never written anywhere.

function Write-PASUITestLine {
    param([string]$Text)
    [Console]::Out.WriteLine($Text)
    if ($script:PASUITest.Log) {
        Add-Content -LiteralPath $script:PASUITest.Log -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $Text) -Encoding UTF8
    }
}

function Assert-PASUIShown {
    # The text of an element must match a pattern (case-sensitive).
    param([string]$Element, [string]$Pattern, [string]$What)
    $text = [string](Get-NativeHTMLKitDocumentText -Document $doc -Element $Element)
    if ($text -cmatch $Pattern) {
        Write-PASUITestLine "PASS $What"
        return
    }
    $script:PASUITest.Failures++
    Write-PASUITestLine ("FAIL $What :: expected /$Pattern/ in: " + $text.Substring(0, [Math]::Min(400, $text.Length)))
}

function Save-PASUISnapshot {
    # Keeps what is on screen now: as an HTML file, and as a picture when a real window is shown.
    param([string]$Name)
    $test = $script:PASUITest
    if ($test.Snapshots) {
        $web = Join-Path $PSScriptRoot 'Web'
        $page = [IO.File]::ReadAllText((Join-Path $web 'index.html'))
        $view = [string](Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_html -Parameters @{ element = 'view' }).html
        $page = $page.Replace('<nav id="steps" aria-label="Steps"></nav>', '<nav id="steps">' + (Get-PASUIStepsHtml $S) + '</nav>')
        $page = $page.Replace('<main id="view"></main>', '<main id="view">' + $view + '</main>')
        $page = $page.Replace('<footer id="bar"></footer>', '<footer id="bar">' + (Get-PASUIBarHtml $S) + '</footer>')
        [IO.File]::WriteAllText((Join-Path $test.Snapshots ($Name + '.html')), $page, (New-Object Text.UTF8Encoding($false)))
        Copy-Item -LiteralPath (Join-Path $web 'style.css') -Destination $test.Snapshots -Force
        if ($test.ScreenshotScript -and -not $env:NATIVEHTMLKIT_TEST_MODE) {
            Start-Sleep -Milliseconds 700
            try {
                & $test.ScreenshotScript -Path (Join-Path $test.Snapshots ($Name + '.png'))
            } catch {
                Write-PASUITestLine ('INFO no screenshot: ' + $_.Exception.Message)
            }
        }
    }
}

function Wait-PASUITestRun {
    # Follows the installation on the run page until it is no longer running.
    param([int]$Minutes)
    $deadline = [datetime]::UtcNow.AddMinutes($Minutes)
    $pause = 500
    if ($Minutes -gt 10) {
        $pause = 5000
    }
    $lastLine = ''
    while ((Test-PASUIRunActive ([string]$S.Run.Status)) -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds $pause
        Update-PASUIRun
        $line = [string]$S.Run.CurrentComponent + ' ' + [string]$S.Run.LastStep
        if ($line -ne $lastLine -and $Minutes -gt 10) {
            $lastLine = $line
            Write-PASUITestLine "INFO installing: $line"
        }
    }
}

function Submit-PASUITestPassword {
    # What the password dialog does when the user types the password and presses Continue.
    param([string]$Password)
    $action = $S.Pending
    $S.Pending = $null
    Close-PASUIDialog 'dlg-password'
    & $action $Password
}

function Invoke-PASUISelfTest {
    param([string]$ScenarioPath)
    $script:PASUITest = @{ Failures = 0; Log = ''; Snapshots = ''; ScreenshotScript = '' }
    try {
        $scenario = Get-Content -LiteralPath $ScenarioPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in @('Log', 'Snapshots', 'ScreenshotScript')) {
            $property = $scenario.PSObject.Properties[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)]
            if ($property -and [string]$property.Value) {
                $script:PASUITest[$name] = [string]$property.Value
            }
        }
        Invoke-PASUITestWalk $scenario
    } catch {
        $script:PASUITest.Failures++
        Write-PASUITestLine ('FAIL the walk stopped: ' + $_.Exception.Message + ' @ ' + $_.ScriptStackTrace)
    }
    Write-PASUITestLine "SELFTEST failures=$($script:PASUITest.Failures)"
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

    Assert-PASUIShown 'view' 'Build a CyberArk PAM lab' 'start page'
    Save-PASUISnapshot '1-start'
    $dropped = @((Invoke-NativeHTMLKitDocumentCommand -Document $doc -Operation get_diagnostics).diagnostics)
    Write-PASUITestLine "INFO the page engine reports $($dropped.Count) dropped or refused item(s)"

    Invoke-PASUIClick 'act-new'
    Assert-PASUIShown 'view' 'Where is the installer media' 'media step'
    Set-PASUIField 'f-mediapath' ([string]$Scenario.media)
    Invoke-PASUIClick 'act-scan'
    Assert-PASUIShown 'media-result' 'PVWA' 'media found'
    Save-PASUISnapshot '2-media'

    Invoke-PASUINext
    Assert-PASUIShown 'view' 'What do you want to build' 'lab step'
    Invoke-PASUIClick ('preset-' + [string]$Scenario.preset)
    $existing = ''
    if ($Scenario.PSObject.Properties['existingVault']) {
        $existing = [string]$Scenario.existingVault
    }
    if ($existing) {
        Invoke-PASUIClick 'vault-Existing'
        Assert-PASUIShown 'view' 'A Vault I already have' 'custom lab'
    }
    Set-PASUIField 'f-labname' $labName
    Save-PASUISnapshot '3-lab'

    Invoke-PASUINext
    Assert-PASUIShown 'view' 'Which servers' 'servers step'
    Invoke-PASUINext
    Assert-PASUIShown 'servers-issues' 'Enter the address' 'missing entries are listed'
    if ($existing) {
        Set-PASUIField 'f-existing' $existing
    }
    $number = 10
    foreach ($slot in Get-PASUIServerSlots $S) {
        $number++
        $address = "192.0.2.$number"
        $entry = $null
        if ($Scenario.PSObject.Properties['servers'] -and $Scenario.servers.PSObject.Properties[$slot.Key]) {
            $entry = $Scenario.servers.PSObject.Properties[$slot.Key].Value
            $address = [string]$entry.address
        }
        Set-PASUIField "srv-$($slot.Key)-addr" $address
        if ($entry -and $entry.PSObject.Properties['name'] -and $slot.Named) {
            Set-PASUIField "srv-$($slot.Key)-name" ([string]$entry.name)
        }
    }
    Set-PASUIField 'f-labpassword' $password
    if ([int]$S.Counts.PSMP -gt 0) {
        Set-PASUIToggle 'f-eula' $true
    }
    Invoke-PASUIClick 'act-preflight'
    Assert-PASUIShown 'preflight-result' 'look ready' 'server check'
    Save-PASUISnapshot '4-servers'

    Invoke-PASUINext
    Assert-PASUIShown 'view' 'Review and install' 'review step'
    Assert-PASUIShown 'view' 'Install the lab' 'the plan is valid and can be installed'
    Save-PASUISnapshot '5-review'

    Invoke-PASUIClick 'act-install'
    Invoke-PASUIClick 'dlg-confirm-yes'
    Assert-PASUIShown 'view' ([regex]::Escape($labName)) 'run page'
    if ($S.LabPassword -or $S.Passwords.Count) {
        $script:PASUITest.Failures++
        Write-PASUITestLine 'FAIL the window still holds a password after the installation started'
    } else {
        Write-PASUITestLine 'PASS no password is kept after the installation started'
    }
    Write-PASUITestLine "INFO run id $($S.RunId)"
    Start-Sleep -Milliseconds 1500
    Update-PASUIRun
    Save-PASUISnapshot '6-run-installing'
    Wait-PASUITestRun -Minutes $timeout

    $round = 0
    while ([string]$S.Run.Status -ne 'Succeeded' -and $Scenario.PSObject.Properties['continueFile'] -and $round -lt 3) {
        $round++
        Assert-PASUIShown 'run-status' 'The installation stopped' "the error is shown (stop $round)"
        Save-PASUISnapshot "6-run-stopped-$round"
        $failure = Get-PASUIFailure $S.Run
        if ($failure) {
            Write-PASUITestLine ("INFO stopped at $($failure.RetryStep): " + $failure.Message.Substring(0, [Math]::Min(300, $failure.Message.Length)))
        } else {
            Write-PASUITestLine ('INFO stopped: ' + [string]$S.Run.Message)
        }
        $flag = [string]$Scenario.continueFile
        $deadline = [datetime]::UtcNow.AddMinutes(30)
        while (-not (Test-Path -LiteralPath $flag) -and [datetime]::UtcNow -lt $deadline) {
            Start-Sleep -Seconds 3
        }
        if (-not (Test-Path -LiteralPath $flag)) {
            throw 'Nobody corrected the cause within 30 minutes'
        }
        Remove-Item -LiteralPath $flag -Force
        if ($failure) {
            Invoke-PASUIClick 'act-retry'
        } else {
            Invoke-PASUIClick 'act-resume'
        }
        Submit-PASUITestPassword $password
        Write-PASUITestLine 'INFO continued from the window'
        Wait-PASUITestRun -Minutes $timeout
    }

    Assert-PASUIShown 'run-status' 'The lab is installed' 'run finished'
    Save-PASUISnapshot '7-run-finished'
    Invoke-PASUIClick 'act-health'
    Submit-PASUITestPassword $password
    Assert-PASUIShown 'run-status' 'Healthy\.' 'lab check'
    Save-PASUISnapshot '8-lab-checked'

    $runId = [string]$S.RunId
    Invoke-PASUIClick 'nav-home'
    Assert-PASUIShown 'view' ([regex]::Escape($labName)) 'start page lists the installation'
    Invoke-PASUIClick "run-$runId"
    Assert-PASUIShown 'run-status' 'The lab is installed' 'the installation can be opened again from the list'
}
