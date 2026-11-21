# PASeasyInstall desktop window, written directly on the NativeHTMLKit SDK (no UI library in between).
#
# This file runs twice: once as the launcher and once as the supervised backend of the native window.
# Nothing with side effects may run above Start-NativeHTMLKitScript.
#
# How it is built:
#   Model.ps1   what the user chose and what follows from it (plain data, testable)
#   Views.ps1   the screens as HTML text (testable)
#   App.ps1     this file: the window, the events and the calls to the installer
# The window talks to the installer ONLY through the commands in Backend/Backend.Contract.ps1.
[CmdletBinding()]
param(
    [string]$Config = '',
    [ValidateSet('Live', 'Mock')][string]$Backend = 'Live',
    [string]$StartDirectory = '',
    # A scenario file (JSON). The window then walks through its own screens as described there, checks
    # what it shows and quits. For automated tests; see SelfTest.ps1.
    [string]$SelfTest = ''
)
$ErrorActionPreference = 'Stop'
Import-Module NativeHTMLKit -ErrorAction Stop
if (-not $StartDirectory) {
    $StartDirectory = (Get-Location).ProviderPath
}
$launchArgs = @('-Backend', $Backend, '-StartDirectory', $StartDirectory)
if ($Config) {
    $launchArgs += @('-Config', $Config)
}
if ($SelfTest) {
    $launchArgs += @('-SelfTest', $SelfTest)
}
$app = Start-NativeHTMLKitScript -Name 'PASeasyInstall' -ScriptPath $PSCommandPath -ArgumentList $launchArgs
# ---- side effects are allowed below this line ----

. (Join-Path $PSScriptRoot 'Backend/Backend.Contract.ps1')
. (Join-Path $PSScriptRoot 'Model.ps1')
. (Join-Path $PSScriptRoot 'Views.ps1')
$null = Import-PASUIBackend -Kind $Backend

function Get-PASUILocalAddress {
    # Best guess at this computer's LAN address: an interface that is up and has a default gateway.
    try {
        $nics = @([Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() | Where-Object {
                $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' })
        $withGateway = @($nics | Where-Object { @($_.GetIPProperties().GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' }).Count })
        foreach ($nic in @($withGateway) + @($nics)) {
            foreach ($unicast in $nic.GetIPProperties().UnicastAddresses) {
                if ($unicast.Address.AddressFamily -eq 'InterNetwork' -and -not [Net.IPAddress]::IsLoopback($unicast.Address)) {
                    return $unicast.Address.ToString()
                }
            }
        }
    } catch {
        return ''
    }
    return ''
}

$S = New-PASUIState -Backend $Backend -StartDirectory $StartDirectory -ControllerAddress (Get-PASUILocalAddress)
$Catalog = @{}
foreach ($type in @('Vault', 'DR', 'PVWA', 'CPM', 'PSM', 'PSMP', 'AD')) {
    $Catalog[$type] = @(Get-PASStageCatalog -Component $type).Count
}

# ------------------------------------------------------------------ drawing

function Set-PASUIHtml {
    param([string]$Element, [string]$Html)
    $null = Set-NativeHTMLKitDocumentHtml -Document $doc -Element $Element -Html $Html
}

function Set-PASUINotice {
    # The one message line under the top bar. Kind: info, ok, error, busy. Empty text removes it.
    param([string]$Kind = 'info', [string]$Text = '')
    if ($Text) {
        $S.Notice = @{ Kind = $Kind; Text = $Text }
    } else {
        $S.Notice = $null
    }
    Set-PASUIHtml 'notice' (Get-PASUINoticeHtml $S)
}

function Show-PASUIScreen {
    # Draws one screen completely: the step line, the page and the bottom bar.
    param([string]$Screen)
    $S.Screen = $Screen
    $html = ''
    switch ($Screen) {
        'home' { $html = Get-PASUIHomeHtml $S }
        'media' { $html = Get-PASUIMediaHtml $S }
        'lab' { $html = Get-PASUILabHtml $S }
        'servers' { $html = Get-PASUIServersHtml $S }
        'review' { $html = Get-PASUIReviewHtml $S }
        'run' { $html = Get-PASUIRunHtml $S $Catalog }
    }
    Set-PASUIHtml 'steps' (Get-PASUIStepsHtml $S)
    Set-PASUIHtml 'view' $html
    Set-PASUIHtml 'bar' (Get-PASUIBarHtml $S)
}

function Invoke-PASUISafe {
    # Runs an action; an error becomes the red message line instead of ending the window.
    param([scriptblock]$Action)
    try {
        & $Action
    } catch {
        Set-PASUINotice 'error' ([string]$_.Exception.Message)
    }
}

function Show-PASUIIssues {
    # Shows what is missing on the current step. Returns $true when nothing is.
    param([string]$Screen)
    $issues = @(Get-PASUIInputIssues $S $Screen)
    $target = $Screen + '-issues'
    if ($Screen -eq 'media') {
        if ($issues.Count) {
            Set-PASUINotice 'error' ($issues -join ' ')
        }
        return (-not $issues.Count)
    }
    Set-PASUIHtml $target (Get-PASUIIssueBoxHtml $issues)
    return (-not $issues.Count)
}

# ------------------------------------------------------------------ dialogs

function Show-PASUIConfirm {
    # Asks a yes/no question. $Action runs when the user confirms.
    param([string]$Title, [string]$Text, [string]$Yes, [scriptblock]$Action)
    $S.Pending = $Action
    $null = Invoke-NativeHTMLKitBatch -Document $doc -Operations @(
        @{ op = 'set_text'; element = 'dlg-confirm-title'; text = $Title }
        @{ op = 'set_text'; element = 'dlg-confirm-text'; text = $Text }
        @{ op = 'set_text'; element = 'dlg-confirm-yes'; text = $Yes }
    )
    Show-NativeHTMLKitHtmlDialog -Document $doc -Element 'dlg-confirm'
}

function Show-PASUIPasswordPrompt {
    # Asks for the lab password. $Action runs with the password as its one argument.
    param([string]$Title, [string]$Text, [scriptblock]$Action)
    $S.Pending = $Action
    $null = Set-NativeHTMLKitDocumentValue -Document $doc -Element 'dlg-password-value' -Value ''
    $null = Invoke-NativeHTMLKitBatch -Document $doc -Operations @(
        @{ op = 'set_text'; element = 'dlg-password-title'; text = $Title }
        @{ op = 'set_text'; element = 'dlg-password-text'; text = $Text }
    )
    Show-NativeHTMLKitHtmlDialog -Document $doc -Element 'dlg-password'
}

function Close-PASUIDialog {
    param([string]$Element)
    Show-NativeHTMLKitHtmlDialog -Document $doc -Element $Element -Close -ReturnValue ''
}

# ------------------------------------------------------------------ installer calls

function ConvertTo-PASUISecure {
    param([string]$Text)
    $secure = New-Object Security.SecureString
    foreach ($character in $Text.ToCharArray()) {
        $secure.AppendChar($character)
    }
    $secure.MakeReadOnly()
    return $secure
}

function Get-PASUIPasswordArguments {
    # The password parameters for Install-PASLab, Test-PASPreflight and Resume-PASRun:
    # -LabPassword, or with separate passwords -CredentialMap (and -SecretMap when asked for).
    param([switch]$WithSecrets)
    if (-not $S.Separate) {
        return @{ LabPassword = (ConvertTo-PASUISecure ([string]$S.LabPassword)) }
    }
    $credentials = @{}
    $secrets = @{}
    foreach ($requirement in @($S.Requirements)) {
        $key = [string]$requirement.Key
        if (-not $S.Passwords.ContainsKey($key) -or -not [string]$S.Passwords[$key]) {
            throw "Enter the password for: $($requirement.Label)"
        }
        $secure = ConvertTo-PASUISecure ([string]$S.Passwords[$key])
        if ([string]$requirement.Kind -eq 'Secret') {
            $secrets[$key] = $secure
        } else {
            $credentials[$key] = New-Object pscredential ([string]$requirement.User, $secure)
        }
    }
    $arguments = @{ CredentialMap = $credentials }
    if ($WithSecrets) {
        $arguments.SecretMap = $secrets
    }
    return $arguments
}

function Update-PASUIPlan {
    # Builds the configuration from the entries and has the installer validate it and lay out the plan.
    # Fills $S.Configuration, $S.Check, $S.Plan and $S.Requirements. Contacts no server.
    $S.Configuration = $null
    $S.Plan = $null
    $S.Requirements = @()
    try {
        $arguments = @{
            Environment = ([string]$S.LabName).Trim()
            VaultMode = [string]$S.VaultMode
            Instances = @(Get-PASUIInstances $S)
            ControllerAddress = ([string]$S.Controller).Trim()
            Username = ([string]$S.WinUser).Trim()
            LinuxUsername = ([string]$S.LinuxUser).Trim()
            Media = $S.MediaSelection
            SecurityProfile = 'Lab'
        }
        foreach ($slot in Get-PASUIServerSlots $S) {
            if ($slot.Key -eq 'vault') {
                $arguments.PrimaryAddress = Get-PASUISlotValue $S $slot 'Address'
            }
            if ($slot.Key -eq 'dr') {
                $arguments.DRAddress = Get-PASUISlotValue $S $slot 'Address'
            }
        }
        if ($S.VaultMode -eq 'Existing') {
            $arguments.ExistingVaultAddress = ([string]$S.ExistingVault).Trim()
        }
        if ($S.AcceptEula) {
            $arguments.AcceptEula = $true
        }
        $configuration = New-PASLabConfiguration @arguments
        $check = Test-PASLabConfiguration -Configuration $configuration -CheckMedia
        $S.Check = @{ Valid = [bool]$check.Valid; Issues = @($check.Issues); Warnings = @($check.Warnings) }
        $S.Configuration = $configuration
        if ($check.Valid) {
            $S.Plan = Get-PASLabPlan -Configuration $configuration
            $S.Requirements = @(Get-PASCredentialRequirement -Configuration $configuration)
        }
    } catch {
        $S.Check = @{ Valid = $false; Issues = @([string]$_.Exception.Message); Warnings = @() }
    }
}

function Invoke-PASUIMediaScan {
    $paths = @(Get-PASUIMediaPaths $S)
    if (-not $paths.Count) {
        throw 'Type, choose or drop the media folder first.'
    }
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "This does not exist: $path"
        }
    }
    Set-PASUINotice 'busy' 'Looking for installers...'
    $S.MediaItems = @(Get-PASMediaInventory -Path $paths)
    $selection = @{}
    if ($S.MediaItems.Count) {
        $selection = Get-PASMediaSelection -Inventory $S.MediaItems
    }
    $S.MediaSelection = $selection
    $S.MediaScanned = $true
    Set-PASUINotice
    if ($S.Screen -eq 'media') {
        Set-PASUIHtml 'media-result' (Get-PASUIMediaResultHtml $S)
    }
}

function Invoke-PASUIPreflight {
    if (-not (Show-PASUIIssues 'servers')) {
        return
    }
    Update-PASUIPlan
    if (-not $S.Check.Valid) {
        Set-PASUIHtml 'servers-issues' (Get-PASUIIssueBoxHtml @($S.Check.Issues) 'The plan has problems')
        return
    }
    if ($S.Separate) {
        throw 'With separate passwords, check the servers from PowerShell: Test-PASPreflight -Path <lab file>'
    }
    Set-PASUINotice 'busy' 'Checking the servers. This can take a minute; the window answers again when it is done.'
    $arguments = Get-PASUIPasswordArguments
    $S.Preflight = @(Test-PASPreflight -Configuration $S.Configuration @arguments)
    Set-PASUINotice
    Set-PASUIHtml 'preflight-result' (Get-PASUIPreflightHtml $S)
}

function Start-PASUIInstall {
    $arguments = Get-PASUIPasswordArguments -WithSecrets
    Set-PASUINotice 'busy' 'Starting the installation...'
    $id = Install-PASLab -Configuration $S.Configuration @arguments -Confirm:$false
    # The installer process has the passwords now. The window keeps none.
    $arguments = $null
    $S.LabPassword = ''
    $S.Passwords = @{}
    $S.RunPlan = @{}
    foreach ($item in @($S.Plan.Items)) {
        $S.RunPlan[[string]$item.Id] = @{ Address = [string]$item.Address }
    }
    Set-PASUINotice
    Open-PASUIRun ([string]$id)
}

function Open-PASUIRun {
    # Shows the page of one installation and keeps it up to date while it runs.
    param([string]$RunId)
    if ($S.RunId -ne $RunId) {
        $S.Health = $null
    }
    $S.RunId = $RunId
    $S.Run = Get-PASRun -RunId $RunId -Tail 1000
    $S.RunSignature = Get-PASUIRunSignature
    Show-PASUIScreen 'run'
    Start-PASUIPoll
}

function Get-PASUIRunSignature {
    # Changes whenever the run page has something new to show.
    $events = @($S.Run.Events)
    $last = ''
    if ($events.Count) {
        $last = [string]$events[-1].TimestampUtc + [string]$events[-1].Event
    }
    return ([string]$S.Run.Status + '|' + $events.Count + '|' + $last)
}

function Update-PASUIRun {
    # Reads the run again and replaces the parts of the run page that show it.
    if ($S.Screen -ne 'run' -or -not $S.RunId) {
        return
    }
    $S.Run = Get-PASRun -RunId $S.RunId -Tail 1000
    $signature = Get-PASUIRunSignature
    if ($signature -eq $S.RunSignature) {
        return
    }
    $S.RunSignature = $signature
    if ($S.ResumeUntil -and (Test-PASUIRunActive ([string]$S.Run.Status))) {
        # The installer process has the run again.
        $S.ResumeUntil = $null
        Set-PASUINotice
    }
    Set-PASUIHtml 'run-status' (Get-PASUIRunStatusHtml $S $Catalog)
    Set-PASUIHtml 'run-comps' (Get-PASUIRunComponentsHtml $S $Catalog)
    Set-PASUIHtml 'run-log' (Get-PASUIRunLogHtml $S)
    Set-PASUIHtml 'run-last' (Get-PASUIRunLastLineHtml $S)
    Set-PASUIHtml 'run-adv' (Get-PASUIRunAdvancedHtml $S)
}

function Start-PASUIPoll {
    # A two-second tick while a running installation is on screen. One tick at a time.
    if ($S.Polling) {
        return
    }
    # After "continue" the run still reads as stopped for a few seconds, until the installer process has
    # taken it over again: keep looking for a while.
    $waitingForResume = ($S.ResumeUntil -and [datetime]::UtcNow -lt $S.ResumeUntil)
    if (-not $S.Run -or $S.Screen -ne 'run') {
        return
    }
    if (-not (Test-PASUIRunActive ([string]$S.Run.Status)) -and -not $waitingForResume) {
        return
    }
    $S.Polling = $true
    $null = Start-NativeHTMLKitTask -Application $app -ScriptBlock { Start-Sleep -Milliseconds 2000 } -OnCompleted {
        $S.Polling = $false
        Invoke-PASUISafe { Update-PASUIRun }
        Start-PASUIPoll
    } -OnFailed {
        $S.Polling = $false
    }
}

function Resume-PASUIRun {
    param([string]$Password, [string]$RetryStep = '')
    $arguments = @{ RunId = [string]$S.RunId; LabPassword = (ConvertTo-PASUISecure $Password) }
    if ($RetryStep) {
        $arguments.RetryStep = @($RetryStep)
    }
    Set-PASUINotice 'busy' 'Continuing the installation...'
    $null = Resume-PASRun @arguments -Confirm:$false
    $S.ResumeUntil = [datetime]::UtcNow.AddSeconds(90)
    $S.Health = $null
    Set-PASUINotice 'info' 'The installation continues. Finished steps are checked again first; this page updates by itself.'
    $S.RunSignature = ''
    Update-PASUIRun
    Start-PASUIPoll
}

function Invoke-PASUIHealth {
    param([string]$Password)
    $credential = New-Object pscredential ('Administrator', (ConvertTo-PASUISecure $Password))
    $arguments = @{ VaultCredential = $credential }
    if ($S.Configuration) {
        $arguments.Configuration = $S.Configuration
    } else {
        $arguments.Path = Join-Path ([string]$S.Run.RunDirectory) 'config.json'
    }
    if (@($S.Run.Components | Where-Object { [string]$_.Type -eq 'DRVault' }).Count) {
        $arguments.DRCredential = $credential
    }
    Set-PASUINotice 'busy' 'Checking the lab...'
    try {
        $S.Health = Test-PASHealth @arguments
    } catch {
        if ([string]$_.Exception.Message -match 'configuration has no PVWA') {
            throw 'This installation has no PVWA of its own, and the lab check asks the Vault through PVWA. Check the lab from the installation that has the PVWA.'
        }
        throw
    }
    Set-PASUINotice
    Set-PASUIHtml 'run-status' (Get-PASUIRunStatusHtml $S $Catalog)
}

function Import-PASUILabFile {
    # Fills the choices from a saved lab file. Media and passwords are not in it and are entered again.
    param([string]$Path)
    $configuration = Import-PASLabConfiguration -Path $Path
    $plan = Get-PASLabPlan -Configuration $configuration
    $S.LabName = [string]$configuration['name']
    $S.Preset = 'custom'
    $S.Slots = @{}
    $types = @($plan.Items | ForEach-Object { [string]$_.Type })
    $S.VaultMode = 'Existing'
    if ($types -contains 'Vault') {
        $S.VaultMode = 'Primary'
    }
    if ($types -contains 'DRVault') {
        $S.VaultMode = 'PrimaryDR'
    }
    foreach ($type in $script:PASUIComponentTypes) {
        $S.Counts[$type] = @($types | Where-Object { $_ -eq $type }).Count
    }
    # A CPM that shares its address with a PVWA was installed on the PVWA server.
    $pvwaAddresses = @($plan.Items | Where-Object { [string]$_.Type -eq 'PVWA' } | ForEach-Object { [string]$_.Address })
    $cpmAddresses = @($plan.Items | Where-Object { [string]$_.Type -eq 'CPM' } | ForEach-Object { [string]$_.Address })
    $S.Colocate = [bool]@($cpmAddresses | Where-Object { $pvwaAddresses -contains $_ }).Count -or -not $cpmAddresses.Count
    $numbers = @{}
    foreach ($item in @($plan.Items)) {
        $type = [string]$item.Type
        if ($type -eq 'Vault') {
            Set-PASUISlotValue $S 'vault' 'Address' ([string]$item.Address)
            continue
        }
        if ($type -eq 'DRVault') {
            Set-PASUISlotValue $S 'dr' 'Address' ([string]$item.Address)
            continue
        }
        if ($type -eq 'CPM' -and $S.Colocate -and $pvwaAddresses -contains [string]$item.Address) {
            continue
        }
        $numbers[$type] = 1 + [int]$numbers[$type]
        $key = $type.ToLowerInvariant() + $numbers[$type]
        Set-PASUISlotValue $S $key 'Address' ([string]$item.Address)
        Set-PASUISlotValue $S $key 'Name' ([string]$item.Name)
    }
    if ($S.VaultMode -eq 'Existing') {
        $S.ExistingVault = [string]$configuration['vault']['address']
    }
}

# ------------------------------------------------------------------ events

function Invoke-PASUIClick {
    param([string]$Id)
    switch -Regex ($Id) {
        '^nav-home$' {
            $S.Runs = @(Get-PASRun)
            Set-PASUINotice
            Show-PASUIScreen 'home'
            return
        }
        '^act-new$' {
            Show-PASUIScreen 'media'
            return
        }
        '^act-open$' {
            $pick = Show-NativeHTMLKitFileDialog -Window $window -Kind OpenFiles -Title 'Open a lab file' -Filters @(@{ name = 'Lab files'; extensions = @('json') })
            if ($pick.cancelled) {
                return
            }
            Import-PASUILabFile ([string]$pick.paths[0])
            Set-PASUINotice 'info' 'Lab file opened. Choose the media folder again; passwords are never stored in a lab file.'
            Show-PASUIScreen 'media'
            return
        }
        '^act-browse$' {
            $pick = Show-NativeHTMLKitFileDialog -Window $window -Kind ChooseFolder -Title 'Folder with the CyberArk installer media'
            if ($pick.cancelled) {
                return
            }
            $S.MediaPath = [string]$pick.paths[0]
            $null = Set-NativeHTMLKitDocumentValue -Document $doc -Element 'f-mediapath' -Value $S.MediaPath
            Invoke-PASUIMediaScan
            return
        }
        '^act-scan$' {
            Invoke-PASUIMediaScan
            return
        }
        '^act-media-clear$' {
            $S.MediaSources = @()
            $S.MediaScanned = $false
            Show-PASUIScreen 'media'
            return
        }
        '^act-back$' {
            $order = @('home', 'media', 'lab', 'servers', 'review')
            $position = [array]::IndexOf($order, [string]$S.Screen)
            if ($position -gt 0) {
                Set-PASUINotice
                Show-PASUIScreen $order[$position - 1]
            }
            return
        }
        '^act-next$' {
            Invoke-PASUINext
            return
        }
        '^step-(media|lab|servers|review)$' {
            Set-PASUINotice
            Show-PASUIScreen $Matches[1]
            return
        }
        '^preset-(\w+)$' {
            Set-PASUIPreset $S $Matches[1]
            Show-PASUIScreen 'lab'
            return
        }
        '^vault-(Primary|PrimaryDR|Existing)$' {
            $S.VaultMode = $Matches[1]
            Show-PASUIScreen 'lab'
            return
        }
        '^cnt-(PVWA|CPM|PSM|PSMP)-(inc|dec)$' {
            $count = [int]$S.Counts[$Matches[1]]
            if ($Matches[2] -eq 'inc' -and $count -lt (Get-PASUIMaxCount $S)) {
                $count++
            }
            if ($Matches[2] -eq 'dec' -and $count -gt 0) {
                $count--
            }
            $S.Counts[$Matches[1]] = $count
            Show-PASUIScreen 'lab'
            return
        }
        '^act-preflight$' {
            Invoke-PASUIPreflight
            return
        }
        '^act-save$' {
            $pick = Show-NativeHTMLKitFileDialog -Window $window -Kind SaveFile -Title 'Save the lab file' -FileName ("PASeasyInstall-$($S.LabName).json") -Directory $S.StartDirectory -Filters @(@{ name = 'Lab files'; extensions = @('json') })
            if ($pick.cancelled) {
                return
            }
            $saved = Export-PASLabConfiguration -Configuration $S.Configuration -Path ([string]$pick.paths[0]) -Force
            Set-PASUINotice 'ok' "Saved: $saved"
            return
        }
        '^act-install$' {
            if ($S.Separate) {
                $null = Get-PASUIPasswordArguments -WithSecrets
            }
            $count = @(Get-PASUIServerSlots $S).Count
            Show-PASUIConfirm 'Install the lab?' "This installs CyberArk on $count server(s) and hardens the Vault server. It cannot be undone from here." 'Install' { Start-PASUIInstall }
            return
        }
        '^run-([0-9a-fA-F]{32})$' {
            $S.RunPlan = @{}
            $S.Configuration = $null
            Open-PASUIRun $Matches[1]
            return
        }
        '^act-retry$' {
            $failure = Get-PASUIFailure $S.Run
            $step = [string]$failure.RetryStep
            Show-PASUIPasswordPrompt 'Try this step again' 'Enter the lab password to continue the installation.' { param($password) Resume-PASUIRun -Password $password -RetryStep $step }.GetNewClosure()
            return
        }
        '^act-resume$' {
            Show-PASUIPasswordPrompt 'Continue the installation' 'Enter the lab password to continue the installation.' { param($password) Resume-PASUIRun -Password $password }
            return
        }
        '^act-health$' {
            Show-PASUIPasswordPrompt 'Check the lab' 'Enter the password of the Vault user Administrator.' { param($password) Invoke-PASUIHealth -Password $password }
            return
        }
        '^act-diag$' {
            $pick = Show-NativeHTMLKitFileDialog -Window $window -Kind SaveFile -Title 'Save the logs' -FileName ("PASeasyInstall-logs-$(([string]$S.RunId).Substring(0, 8)).zip") -Directory $S.StartDirectory -Filters @(@{ name = 'ZIP'; extensions = @('zip') })
            if ($pick.cancelled) {
                return
            }
            Set-PASUINotice 'busy' 'Collecting the logs...'
            $null = Export-PASDiagnostics -RunId ([string]$S.RunId) -Path ([string]$pick.paths[0]) -Force
            Set-PASUINotice 'ok' "Logs saved: $($pick.paths[0]). Passwords are not part of them."
            return
        }
        '^act-stop$' {
            Show-PASUIConfirm 'Stop the installation?' 'The step that is running on the server is not interrupted, but nothing new is started. You can continue the installation later.' 'Stop' {
                $null = Stop-PASRun -RunId ([string]$S.RunId) -Confirm:$false
                $S.RunSignature = ''
                Update-PASUIRun
            }
            return
        }
        '^dlg-confirm-yes$' {
            $action = $S.Pending
            $S.Pending = $null
            Close-PASUIDialog 'dlg-confirm'
            if ($action) {
                & $action
            }
            return
        }
        '^dlg-confirm-no$' {
            $S.Pending = $null
            Close-PASUIDialog 'dlg-confirm'
            return
        }
        '^dlg-password-no$' {
            $S.Pending = $null
            Close-PASUIDialog 'dlg-password'
            return
        }
    }
}

function Invoke-PASUINext {
    # Next on the bottom bar: the step must be complete, then the following screen is drawn.
    switch ([string]$S.Screen) {
        'media' {
            if (-not $S.MediaScanned -and @(Get-PASUIMediaPaths $S).Count) {
                Invoke-PASUIMediaScan
            }
            if (Show-PASUIIssues 'media') {
                Show-PASUIScreen 'lab'
            }
        }
        'lab' {
            if (Show-PASUIIssues 'lab') {
                Show-PASUIScreen 'servers'
            }
        }
        'servers' {
            if (Show-PASUIIssues 'servers') {
                Set-PASUINotice 'busy' 'Preparing the plan...'
                Update-PASUIPlan
                Set-PASUINotice
                Show-PASUIScreen 'review'
            }
        }
    }
}

function Set-PASUIField {
    # A text field changed: remember what was typed. Nothing is drawn again, so the caret stays put.
    param([string]$Id, [string]$Value)
    switch -Regex ($Id) {
        '^f-mediapath$' {
            $S.MediaPath = $Value
            $S.MediaScanned = $false
            return
        }
        '^f-labname$' { $S.LabName = $Value; return }
        '^f-existing$' { $S.ExistingVault = $Value; return }
        '^f-labpassword$' { $S.LabPassword = $Value; return }
        '^f-winuser$' { $S.WinUser = $Value; return }
        '^f-linuxuser$' { $S.LinuxUser = $Value; return }
        '^f-controller$' { $S.Controller = $Value; return }
        '^srv-([a-z0-9]+)-name$' { Set-PASUISlotValue $S $Matches[1] 'Name' $Value; return }
        '^srv-([a-z0-9]+)-addr$' {
            Set-PASUISlotValue $S $Matches[1] 'Address' $Value
            $S.Preflight = $null
            return
        }
        '^pw-(\d+)$' {
            $requirement = @($S.Requirements)[[int]$Matches[1]]
            if ($requirement) {
                $S.Passwords[[string]$requirement.Key] = $Value
            }
            return
        }
    }
}

function Set-PASUIToggle {
    # A checkbox changed.
    param([string]$Id, [bool]$Checked)
    switch ($Id) {
        'opt-advanced' {
            $S.Advanced = $Checked
            if (-not $Checked) {
                foreach ($type in $script:PASUIComponentTypes) {
                    if ([int]$S.Counts[$type] -gt 2) {
                        $S.Counts[$type] = 2
                    }
                }
            }
            Show-PASUIScreen ([string]$S.Screen)
        }
        'f-colocate' {
            $S.Colocate = $Checked
        }
        'f-eula' {
            $S.AcceptEula = $Checked
        }
        'f-separate' {
            $S.Separate = $Checked
            Show-PASUIScreen 'servers'
        }
    }
}

# ------------------------------------------------------------------ window

try {
    # Small by default: the window is made to sit next to other windows. It stays usable down to the minimum.
    $window = New-NativeHTMLKitWindow -Application $app -Title 'PASeasyInstall' -Width 800 -Height 560 -MinWidth 480 -MinHeight 340
    $doc = Open-NativeHTMLKitFile -Window $window -Path (Join-Path (Join-Path $PSScriptRoot 'Web') 'index.html')
    if ($Backend -eq 'Mock') {
        $null = Set-NativeHTMLKitDocumentAttribute -Document $doc -Element 'mode-badge' -Name 'hidden' -Remove
    }

    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type click -Callback {
        param($evt)
        $id = [string]$evt.element
        if ($id) {
            Invoke-PASUISafe { Invoke-PASUIClick $id }
        }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type input -Callback {
        param($evt)
        Set-PASUIField ([string]$evt.element) ([string]$evt.value)
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type change -Callback {
        param($evt)
        $id = [string]$evt.element
        if ($id -in @('opt-advanced', 'f-colocate', 'f-eula', 'f-separate')) {
            Invoke-PASUISafe { Set-PASUIToggle $id ([bool]$evt.checked) }
        }
    }
    # Files and folders dropped from Explorer onto the media step (the element marked data-nativehtmlkit-drop).
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type drop -Callback {
        param($evt)
        $paths = @()
        $property = $evt.PSObject.Properties['paths']
        if ($property) {
            $paths = @($property.Value | ForEach-Object { [string]$_ })
        }
        if (-not $paths.Count -or $S.Screen -ne 'media') {
            return
        }
        Invoke-PASUISafe {
            $folders = @($paths | ForEach-Object { [bool](Test-Path -LiteralPath $_ -PathType Container) })
            Add-PASUIMediaDrop -State $S -Paths $paths -IsFolder $folders
            Show-PASUIScreen 'media'
            Invoke-PASUIMediaScan
        }
    }
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element 'dlg-password-form' -Callback {
        $password = [string](Get-NativeHTMLKitValue -Document $doc -Element 'dlg-password-value')
        $action = $S.Pending
        $S.Pending = $null
        $null = Set-NativeHTMLKitDocumentValue -Document $doc -Element 'dlg-password-value' -Value ''
        Close-PASUIDialog 'dlg-password'
        if ($action -and $password) {
            Invoke-PASUISafe { & $action $password }
        }
    }

    if ($Config) {
        Invoke-PASUISafe { Import-PASUILabFile $Config }
    }
    $S.Runs = @(Get-PASRun)
    Show-PASUIScreen 'home'
    Set-NativeHTMLKitReady -Application $app
    if ($SelfTest) {
        . (Join-Path $PSScriptRoot 'SelfTest.ps1')
        Invoke-PASUISelfTest -ScenarioPath $SelfTest
        $null = Request-NativeHTMLKitQuit -Application $app
    }
    Wait-NativeHTMLKit -Application $app -UntilShutdown
} finally {
    Close-NativeHTMLKit -Application $app
}
