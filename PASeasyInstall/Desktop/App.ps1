# PASeasyInstall desktop window, written directly on the NativeHTMLKit SDK (no UI library in between).
#
# This file runs twice: once as the launcher and once as the supervised backend of the native window.
# Nothing with side effects may run above Start-NativeHTMLKitScript.
#
# How it is built:
#   Model.ps1   what the user chose and what follows from it (plain data, testable)
#   Views.ps1   the screens as HTML text (testable)
#   App.ps1     this file: the window, the events and the calls to the installer
# The window talks to the installer ONLY through the public commands listed in Backend/Backend.Contract.ps1.
# It is started by Start-PASeasyInstall and is part of the PASeasyInstall module (folder Desktop).
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
# The window engine: the installed module, or the copy next to the PASeasyInstall folder (portable ZIP).
if (Get-Module -ListAvailable -Name NativeHTMLKit) {
    Import-Module NativeHTMLKit -ErrorAction Stop
} else {
    $bundledKit = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'NativeHTMLKit'
    $kitManifest = Get-ChildItem -LiteralPath $bundledKit -Recurse -Filter 'NativeHTMLKit.psd1' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $kitManifest) {
        throw 'The NativeHTMLKit module is not installed. Install-Module NativeHTMLKit -Scope CurrentUser'
    }
    Import-Module $kitManifest.FullName -ErrorAction Stop
}
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

function Request-PASUIAccounts {
    # Runs $Action with the accounts and Vault passwords of the installation on screen:
    # @{ Credentials = @{ key = PSCredential }; Secrets = @{ key = SecureString } }.
    # They are still in memory when the installation was started from this window. Otherwise a dialog
    # asks for them: one password per entry of $Requirements (Kind, Key, User, Label).
    param([string]$Title, [string]$Text, [object[]]$Requirements, [scriptblock]$Action)
    if ($S.Kept -and [string]$S.Kept.RunId -eq [string]$S.RunId) {
        & $Action $S.Kept
        return
    }
    if (-not @($Requirements).Count) {
        throw "This window does not know the accounts of this installation any more. Continue it from PowerShell: Resume-PASRun -RunId $($S.RunId)"
    }
    $S.Pending = $Action
    $S.DialogRequirements = @($Requirements)
    $fields = New-Object System.Text.StringBuilder
    $index = 0
    foreach ($requirement in @($Requirements)) {
        [void]$fields.Append("<div class=`"field`"><label for=`"cred-$index`">" + (ConvertTo-PASUIText $requirement.Label) + "</label><input type=`"password`" id=`"cred-$index`" autocomplete=`"off`"></div>")
        $index++
    }
    $null = Invoke-NativeHTMLKitBatch -Document $doc -Operations @(
        @{ op = 'set_text'; element = 'dlg-creds-title'; text = $Title }
        @{ op = 'set_text'; element = 'dlg-creds-text'; text = $Text }
    )
    Set-PASUIHtml 'dlg-creds-fields' $fields.ToString()
    Show-NativeHTMLKitHtmlDialog -Document $doc -Element 'dlg-creds'
}

function Submit-PASUIAccounts {
    # The accounts dialog was confirmed: read the passwords, close it and run what was waiting.
    $action = $S.Pending
    $requirements = @($S.DialogRequirements)
    $S.Pending = $null
    $S.DialogRequirements = @()
    $credentials = @{}
    $secrets = @{}
    $index = 0
    $missing = $false
    foreach ($requirement in $requirements) {
        $value = [string](Get-NativeHTMLKitValue -Document $doc -Element "cred-$index")
        $index++
        if (-not $value) {
            $missing = $true
            continue
        }
        $secure = ConvertTo-PASUISecure $value
        if ([string]$requirement.Kind -eq 'Secret') {
            $secrets[[string]$requirement.Key] = $secure
        } else {
            $credentials[[string]$requirement.Key] = New-Object pscredential ([string]$requirement.User, $secure)
        }
    }
    Set-PASUIHtml 'dlg-creds-fields' ''
    Close-PASUIDialog 'dlg-creds'
    if ($missing) {
        throw 'Every password is needed. Nothing was done.'
    }
    if ($action) {
        & $action @{ RunId = [string]$S.RunId; Credentials = $credentials; Secrets = $secrets }
    }
}

function Get-PASUIRunRequirements {
    # What an installation opened from the list needs to continue: read from the configuration stored with it.
    # -Only limits the list to these keys.
    param([string[]]$Only = @())
    $requirements = @()
    try {
        $requirements = @(Get-PASCredentialRequirement -Path (Join-Path ([string]$S.Run.RunDirectory) 'config.json'))
    } catch {
        $requirements = @()
    }
    if ($Only.Count) {
        $requirements = @($requirements | Where-Object { [string]$_.Key -in $Only })
    }
    return @($requirements)
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

function Get-PASUIFormAccounts {
    # The accounts and Vault passwords typed on the Servers step, as Install-PASLab and Test-PASPreflight want them:
    # @{ Credentials = @{ key = PSCredential }; Secrets = @{ key = SecureString } }. Needs the plan ($S.Requirements).
    $credentials = @{}
    $secrets = @{}
    $slots = @(Get-PASUIServerSlots $S)
    foreach ($requirement in @($S.Requirements)) {
        $key = [string]$requirement.Key
        if ([string]$requirement.Kind -eq 'Secret') {
            if (-not $S.Secrets.ContainsKey($key) -or -not [string]$S.Secrets[$key]) {
                throw "Enter: $($requirement.Label)"
            }
            $secrets[$key] = ConvertTo-PASUISecure ([string]$S.Secrets[$key])
            continue
        }
        # A server account: the form line with the address of that server.
        $address = [string]$S.Configuration.hosts[[string]$requirement.HostId].address
        $slot = @($slots | Where-Object { (Get-PASUISlotValue $S $_ 'Address') -eq $address }) | Select-Object -First 1
        if (-not $slot -or -not (Get-PASUISlotValue $S $slot 'Password')) {
            throw "Enter the password for: $($requirement.Label)"
        }
        $credentials[$key] = New-Object pscredential ((Get-PASUISlotValue $S $slot 'User'), (ConvertTo-PASUISecure (Get-PASUISlotValue $S $slot 'Password')))
    }
    return @{ Credentials = $credentials; Secrets = $secrets }
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
            Username = 'Administrator'
            LinuxUsername = 'root'
            Media = $S.MediaSelection
            SecurityProfile = 'Lab'
        }
        foreach ($slot in Get-PASUIServerSlots $S) {
            if ($slot.Key -eq 'vault') {
                $arguments.PrimaryAddress = Get-PASUISlotValue $S $slot 'Address'
                $arguments.PrimaryUsername = Get-PASUISlotValue $S $slot 'User'
            }
            if ($slot.Key -eq 'dr') {
                $arguments.DRAddress = Get-PASUISlotValue $S $slot 'Address'
                $arguments.DRUsername = Get-PASUISlotValue $S $slot 'User'
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

function Start-PASUIServerCheck {
    # "Next" on the Servers step. First, within seconds: does every server answer at all? Then, in the
    # background so that the window stays usable: sign in to each one and check that it is ready.
    # Only when everything passed the review step is shown.
    Update-PASUIPlan
    if (-not $S.Check.Valid) {
        Set-PASUIHtml 'servers-issues' (Get-PASUIIssueBoxHtml @($S.Check.Issues) 'The plan has problems')
        return
    }
    $accounts = Get-PASUIFormAccounts
    Set-PASUINotice 'busy' 'Looking for the servers...'
    $S.Preflight = @(Test-PASPreflight -Configuration $S.Configuration -ConnectivityOnly)
    Set-PASUINotice
    if (@($S.Preflight | Where-Object { $_.Passed -is [bool] -and -not $_.Passed }).Count) {
        Set-PASUIHtml 'preflight-result' (Get-PASUIPreflightHtml $S)
        return
    }
    $S.Checking = $true
    Set-PASUIHtml 'preflight-result' (Get-PASUIPreflightHtml $S)
    Set-PASUIHtml 'bar' (Get-PASUIBarHtml $S)
    $contract = Join-Path (Join-Path $PSScriptRoot 'Backend') 'Backend.Contract.ps1'
    try {
        $null = Start-NativeHTMLKitTask -Application $app -ArgumentList @($contract, [string]$S.Backend, $S.Configuration, $accounts.Credentials) -ScriptBlock {
            param([string]$ContractPath, [string]$Kind, $Configuration, [hashtable]$CredentialMap)
            . $ContractPath
            $null = Import-PASUIBackend -Kind $Kind
            Test-PASPreflight -Configuration $Configuration -CredentialMap $CredentialMap
        } -OnCompleted {
            param($result)
            Invoke-PASUISafe { Complete-PASUIServerCheck @($result) }
        } -OnFailed {
            param($failure)
            $S.Checking = $false
            Set-PASUINotice 'error' ('The servers could not be checked: ' + [string]$failure.Message)
            if ($S.Screen -eq 'servers') {
                Set-PASUIHtml 'preflight-result' (Get-PASUIPreflightHtml $S)
                Set-PASUIHtml 'bar' (Get-PASUIBarHtml $S)
            }
        }
    } catch {
        # No background task could be started: check here. The window does not react until it is done.
        Complete-PASUIServerCheck @(Test-PASPreflight -Configuration $S.Configuration -CredentialMap $accounts.Credentials)
    }
}

function Complete-PASUIServerCheck {
    param([object[]]$Rows)
    $S.Checking = $false
    $S.Preflight = @($Rows)
    if ($S.Screen -ne 'servers') {
        return
    }
    if (@($Rows | Where-Object { $_.Passed -is [bool] -and -not $_.Passed }).Count) {
        Set-PASUIHtml 'preflight-result' (Get-PASUIPreflightHtml $S)
        Set-PASUIHtml 'bar' (Get-PASUIBarHtml $S)
        return
    }
    Show-PASUIScreen 'review'
}

function Start-PASUIInstall {
    # Starts the installation in the background, the way the server check runs, so that the window stays
    # usable for the half minute the installer needs to check the plan and start its own process.
    if ($S.Starting) {
        return
    }
    $accounts = Get-PASUIFormAccounts
    $S.Starting = $accounts
    Set-PASUINotice 'busy' 'Starting the installation...'
    if ([string]$S.Backend -eq 'Mock') {
        # The simulated installer keeps its runs in the memory of this window and starts at once.
        Start-PASUIInstallHere
        return
    }
    $contract = Join-Path (Join-Path $PSScriptRoot 'Backend') 'Backend.Contract.ps1'
    try {
        $null = Start-NativeHTMLKitTask -Application $app -ArgumentList @($contract, [string]$S.Backend, $S.Configuration, $accounts.Credentials, $accounts.Secrets) -ScriptBlock {
            param([string]$ContractPath, [string]$Kind, $Configuration, [hashtable]$CredentialMap, [hashtable]$SecretMap)
            . $ContractPath
            $null = Import-PASUIBackend -Kind $Kind
            Install-PASLab -Configuration $Configuration -CredentialMap $CredentialMap -SecretMap $SecretMap -Confirm:$false
        } -OnCompleted {
            param($result)
            Invoke-PASUISafe { Complete-PASUIInstallStart ([string](@($result)[-1])) }
        } -OnFailed {
            param($failure)
            $S.Starting = $null
            Set-PASUINotice 'error' ('The installation was not started: ' + [string]$failure.Message)
        }
    } catch {
        # No background task could be started. The window does not react until the installation is started.
        Start-PASUIInstallHere
    }
}

function Start-PASUIInstallHere {
    # Starts the installation in the window's own thread, with the accounts in $S.Starting.
    try {
        $id = Install-PASLab -Configuration $S.Configuration -CredentialMap $S.Starting.Credentials -SecretMap $S.Starting.Secrets -Confirm:$false
    } catch {
        $S.Starting = $null
        throw
    }
    Complete-PASUIInstallStart ([string]$id)
}

function Complete-PASUIInstallStart {
    param([string]$RunId)
    $accounts = $S.Starting
    $S.Starting = $null
    if ($RunId -notmatch '^[0-9a-fA-F]{32}$') {
        throw "The installation was not started: the installer returned no run id ($RunId)."
    }
    # The installer process has the passwords now. The window keeps them only as protected objects, for
    # "Try again" and "Check the lab", until it is closed. What was typed is forgotten.
    $S.Kept = @{ RunId = $RunId; Credentials = $accounts.Credentials; Secrets = $accounts.Secrets }
    foreach ($key in @($S.Slots.Keys)) {
        $S.Slots[$key].Remove('Password')
    }
    $S.Secrets = @{}
    $S.Preflight = $null
    $S.RunPlan = @{}
    foreach ($item in @($S.Plan.Items)) {
        $S.RunPlan[[string]$item.Id] = @{ Address = [string]$item.Address }
    }
    Set-PASUINotice
    Open-PASUIRun $RunId
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
    param([hashtable]$Accounts, [string]$RetryStep = '')
    $arguments = @{ RunId = [string]$S.RunId; CredentialMap = $Accounts.Credentials; SecretMap = $Accounts.Secrets }
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
    param([hashtable]$Accounts)
    if (-not $Accounts.Secrets.ContainsKey('VaultAdmin')) {
        throw 'The lab check needs the password of the Vault user Administrator.'
    }
    $arguments = @{ VaultCredential = (New-Object pscredential ('Administrator', $Accounts.Secrets['VaultAdmin'])) }
    if ($S.Configuration) {
        $arguments.Configuration = $S.Configuration
    } else {
        $arguments.Path = Join-Path ([string]$S.Run.RunDirectory) 'config.json'
    }
    if ($Accounts.Credentials.ContainsKey('dr01')) {
        $arguments.DRCredential = $Accounts.Credentials['dr01']
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
        $account = [string]$configuration['hosts'][[string]$item.Host]['user']
        if ($type -eq 'Vault') {
            Set-PASUISlotValue $S 'vault' 'Address' ([string]$item.Address)
            Set-PASUISlotValue $S 'vault' 'User' $account
            continue
        }
        if ($type -eq 'DRVault') {
            Set-PASUISlotValue $S 'dr' 'Address' ([string]$item.Address)
            Set-PASUISlotValue $S 'dr' 'User' $account
            continue
        }
        if ($type -eq 'CPM' -and $S.Colocate -and $pvwaAddresses -contains [string]$item.Address) {
            continue
        }
        $numbers[$type] = 1 + [int]$numbers[$type]
        $key = $type.ToLowerInvariant() + $numbers[$type]
        Set-PASUISlotValue $S $key 'Address' ([string]$item.Address)
        Set-PASUISlotValue $S $key 'Name' ([string]$item.Name)
        Set-PASUISlotValue $S $key 'User' $account
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
            $null = Get-PASUIFormAccounts
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
            Request-PASUIAccounts 'Try this step again' 'The accounts are needed again to continue the installation.' (Get-PASUIRunRequirements) { param($accounts) Resume-PASUIRun -Accounts $accounts -RetryStep $step }.GetNewClosure()
            return
        }
        '^act-resume$' {
            Request-PASUIAccounts 'Continue the installation' 'The accounts are needed again to continue the installation.' (Get-PASUIRunRequirements) { param($accounts) Resume-PASUIRun -Accounts $accounts }
            return
        }
        '^act-health$' {
            Request-PASUIAccounts 'Check the lab' 'The lab check signs in to the Vault through PVWA.' (Get-PASUIRunRequirements -Only @('VaultAdmin', 'dr01')) { param($accounts) Invoke-PASUIHealth -Accounts $accounts }
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
        '^dlg-creds-no$' {
            $S.Pending = $null
            $S.DialogRequirements = @()
            Set-PASUIHtml 'dlg-creds-fields' ''
            Close-PASUIDialog 'dlg-creds'
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
            if ($S.Checking) {
                return
            }
            if (Show-PASUIIssues 'servers') {
                Start-PASUIServerCheck
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
        '^sec-(VaultAdmin|VaultMaster|DRPassword)$' { $S.Secrets[$Matches[1]] = $Value; return }
        '^f-controller$' { $S.Controller = $Value; return }
        '^srv-([a-z0-9]+)-name$' { Set-PASUISlotValue $S $Matches[1] 'Name' $Value; return }
        '^srv-([a-z0-9]+)-user$' { Set-PASUISlotValue $S $Matches[1] 'User' $Value; return }
        '^srv-([a-z0-9]+)-pass$' { Set-PASUISlotValue $S $Matches[1] 'Password' $Value; return }
        '^srv-([a-z0-9]+)-addr$' {
            Set-PASUISlotValue $S $Matches[1] 'Address' $Value
            $S.Preflight = $null
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
        if ($id -in @('opt-advanced', 'f-colocate', 'f-eula')) {
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
    $null = Register-NativeHTMLKitDocumentEvent -Document $doc -Type submit -Element 'dlg-creds-form' -Callback {
        Invoke-PASUISafe { Submit-PASUIAccounts }
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
