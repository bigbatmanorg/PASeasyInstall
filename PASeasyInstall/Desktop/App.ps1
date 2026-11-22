# PASeasyInstall desktop window (WPF, part of Windows; no other module is needed).
#
# How it is built:
#   Window.xaml    the shell of the window and every style
#   Model.ps1      what the user chose and what follows from it (plain data, testable)
#   Controls.ps1   one function per kind of control, and the helper that runs work away from the window's thread
#   Views.ps1      the screens, built from those controls
#   App.ps1        this file: the window, the events and the calls to the installer
# The window talks to the installer ONLY through the public commands listed in Backend/Backend.Contract.ps1,
# and every such call that can take time runs away from the window's thread (Start-PASUITask), so the window
# never stops reacting. It is started by Start-PASeasyInstall and is part of the PASeasyInstall module.
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
if (-not $StartDirectory) {
    $StartDirectory = (Get-Location).ProviderPath
}

# WPF needs a single-threaded apartment. Windows PowerShell 5.1 starts that way; anything else starts again.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath, '-Backend', $Backend, '-StartDirectory', $StartDirectory)
    if ($Config) {
        $relaunch += @('-Config', $Config)
    }
    if ($SelfTest) {
        $relaunch += @('-SelfTest', $SelfTest)
    }
    & $exe @relaunch
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, UIAutomationProvider, UIAutomationTypes

. (Join-Path $PSScriptRoot 'Backend/Backend.Contract.ps1')
. (Join-Path $PSScriptRoot 'Model.ps1')
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
foreach ($type in @('Vault', 'DR', 'PVWA', 'CPM', 'PSM', 'PSMP', 'HTML5GW', 'PTA', 'AD')) {
    $Catalog[$type] = @(Get-PASStageCatalog -Component $type).Count
}

# ------------------------------------------------------------------ window

$window = [Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Window.xaml')))
$ui = @{}
foreach ($name in @('Shell', 'Main', 'NavHome', 'BrandIcon', 'Steps', 'OptAdvanced', 'SimBadge', 'Notice', 'NoticeIcon', 'NoticeText',
        'Bar', 'BtnBack', 'BtnNext', 'NextBusy', 'NextText', 'NextArrow', 'BarText', 'Page', 'PageHost',
        'Overlay', 'DialogTitle', 'DialogText', 'DialogFields', 'DialogHint', 'DialogNo', 'DialogYes')) {
    $ui[$name] = $window.FindName($name)
}
# The parts of the current page that are filled again on their own (Views.ps1).
$R = @{}
# The password boxes by id (srv-<server>-pass, sec-<Vault password>). They outlive a page: what was typed
# stays in the box, as a SecureString, and is read from there when it is needed. Nothing else holds it.
$PasswordBoxes = @{}
# The password boxes of the accounts dialog, in the order of $S.DialogRequirements.
$DialogBoxes = New-Object System.Collections.ArrayList

$iconPath = Join-Path $PSScriptRoot 'PASeasyInstall.ico'
if (Test-Path -LiteralPath $iconPath) {
    $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath)
    $ui.BrandIcon.Source = $window.Icon
}
if ($Backend -eq 'Mock') {
    $ui.SimBadge.Visibility = 'Visible'
}
# The dialog buttons answer Enter and Esc only while the dialog is shown.
$ui.DialogYes.IsDefault = $false
$ui.DialogNo.IsCancel = $false

# Two things Windows is asked directly, because WPF has no setting for them. Both are cosmetic or a safety
# net, so a failure is ignored.
#   - A dark title bar to match the window (Windows 10 20H1 / Server 2022 and later; older ones keep theirs).
#   - Start-PASeasyInstall starts this process with a hidden console. Should Windows apply "hidden" to the
#     first window of the process as well, the window is shown once more, which Windows then does.
$native = @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
'@
$window.Add_SourceInitialized({
        try {
            if (-not ('PASeasyInstall.NativeWindow' -as [type])) {
                Add-Type -Namespace PASeasyInstall -Name NativeWindow -MemberDefinition $native
            }
            $handle = (New-Object Windows.Interop.WindowInteropHelper($window)).Handle
            $on = 1
            if ([PASeasyInstall.NativeWindow]::DwmSetWindowAttribute($handle, 20, [ref]$on, 4) -ne 0) {
                [void][PASeasyInstall.NativeWindow]::DwmSetWindowAttribute($handle, 19, [ref]$on, 4)
            }
        } catch {
            $null = $_
        }
    })
$window.Add_Loaded({
        $null = $window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::ContextIdle, [Action]{
                try {
                    $handle = (New-Object Windows.Interop.WindowInteropHelper($window)).Handle
                    if (-not [PASeasyInstall.NativeWindow]::IsWindowVisible($handle)) {
                        [void][PASeasyInstall.NativeWindow]::ShowWindow($handle, 5)
                    }
                } catch {
                    $null = $_
                }
            })
    })

. (Join-Path $PSScriptRoot 'Controls.ps1')
. (Join-Path $PSScriptRoot 'Views.ps1')

# ------------------------------------------------------------------ drawing

function Set-PASUINotice {
    # The one message line under the top bar. Kind: info, ok, error, busy. Empty text removes it.
    param([string]$Kind = 'info', [string]$Text = '')
    if ($Text) {
        $S.Notice = @{ Kind = $Kind; Text = $Text }
    } else {
        $S.Notice = $null
    }
    Show-PASUINotice
}

function Show-PASUIScreen {
    # Draws one screen completely: the step line, the page and the bottom bar.
    param([string]$Screen)
    $changed = ([string]$S.Screen -ne $Screen)
    $S.Screen = $Screen
    $R.Clear()
    $ui.PageHost.Children.Clear()
    switch ($Screen) {
        'home' { Add-PASUIHomePage $ui.PageHost }
        'media' { Add-PASUIMediaPage $ui.PageHost }
        'lab' { Add-PASUILabPage $ui.PageHost }
        'servers' { Add-PASUIServersPage $ui.PageHost }
        'review' { Add-PASUIReviewPage $ui.PageHost }
        'run' { Add-PASUIRunPage $ui.PageHost }
    }
    Show-PASUISteps
    Show-PASUIBar
    # The Advanced switch is shown only on a page that has something more to show.
    $ui.OptAdvanced.IsChecked = [bool]$S.Advanced
    if (Test-PASUIAdvancedApplies $S) {
        $ui.OptAdvanced.Visibility = 'Visible'
    } else {
        $ui.OptAdvanced.Visibility = 'Collapsed'
    }
    if ($changed) {
        $ui.Page.ScrollToHome()
    }
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
    if ($Screen -eq 'servers') {
        $issues = @(Get-PASUIFormIssues)
        Set-PASUIRegion 'ServersIssues' @((New-PASUIIssueBox $issues))
        if ($issues.Count) {
            Set-PASUIRegion 'PreflightResult'
            $ui.Page.ScrollToEnd()
        }
        return (-not $issues.Count)
    }
    $issues = @(Get-PASUIInputIssues $S $Screen)
    if ($Screen -eq 'media') {
        if ($issues.Count) {
            Set-PASUINotice 'error' ($issues -join ' ')
        }
        return (-not $issues.Count)
    }
    Set-PASUIRegion 'LabIssues' @((New-PASUIIssueBox $issues))
    if ($issues.Count) {
        $ui.Page.ScrollToEnd()
    }
    return (-not $issues.Count)
}

# ------------------------------------------------------------------ passwords: SecureString only

function Get-PASUITypedSecret {
    # A protected copy of what was typed into a password box, or $null when it is empty.
    param([string]$Id)
    if (-not $PasswordBoxes.ContainsKey($Id) -or -not $PasswordBoxes[$Id].SecurePassword.Length) {
        return $null
    }
    $copy = $PasswordBoxes[$Id].SecurePassword.Copy()
    $copy.MakeReadOnly()
    return $copy
}

function Test-PASUISecureText {
    # Does a SecureString match a pattern? The text is unprotected only inside this function, as a BSTR
    # that is zeroed at once. Used for the character rule of the Vault passwords.
    param([Security.SecureString]$Secure, [string]$Pattern)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) -match $Pattern)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Get-PASUIFormIssues {
    # What is missing on the Servers step: the list of the model, and the character rule of the Vault
    # passwords, which the model cannot check because it never sees them.
    $issues = @(Get-PASUIInputIssues $S 'servers')
    foreach ($field in Get-PASUIVaultSecrets $S) {
        $secure = Get-PASUITypedSecret ('sec-' + [string]$field.Key)
        if ($secure -and -not (Test-PASUISecureText $secure '^[\x21\x23-\x7E]+$')) {
            $issues += "The $($field.Label) may hold letters, digits and the usual signs, but no space and no double quote."
        }
    }
    return @($issues)
}

function Clear-PASUIPasswords {
    # Forgets every password that was typed into the Servers form.
    foreach ($box in @($PasswordBoxes.Values)) {
        $box.Clear()
    }
    foreach ($key in @($S.Slots.Keys)) {
        $S.Slots[$key].Remove('Password')
    }
    $S.Secrets = @{}
}

function Get-PASUIFormAccounts {
    # The accounts and Vault passwords typed on the Servers step, as Install-PASLab and Test-PASPreflight want them:
    # @{ Credentials = @{ key = PSCredential }; Secrets = @{ key = SecureString } }. Needs the plan ($S.Requirements).
    $credentials = @{}
    $secrets = @{}
    $slots = @(Get-PASUIServerSlots $S)
    $domainSlot = Get-PASUIDomainSlot $S
    foreach ($requirement in @($S.Requirements)) {
        $key = [string]$requirement.Key
        # The domain line of the form answers three things: the password the servers join with, the domain
        # account that installs PSM on a domain member, and (new domain) the restore mode password.
        if ($domainSlot -and $key -in @('DomainJoinPassword', 'ADSafeMode', 'PSMDomainInstaller')) {
            $domainPassword = Get-PASUITypedSecret ('srv-' + [string]$domainSlot.Key + '-pass')
            if (-not $domainPassword) {
                throw "Enter the password for: $($domainSlot.Roles)"
            }
            if ($key -eq 'PSMDomainInstaller') {
                $credentials[$key] = New-Object pscredential ([string]$requirement.User, $domainPassword)
            } else {
                $secrets[$key] = $domainPassword
            }
            continue
        }
        if ([string]$requirement.Kind -eq 'Secret') {
            $secret = Get-PASUITypedSecret ('sec-' + $key)
            if (-not $secret) {
                throw "Enter: $($requirement.Label)"
            }
            $secrets[$key] = $secret
            continue
        }
        # A server account: the form line with the address of that server.
        $address = [string]$S.Configuration.hosts[[string]$requirement.HostId].address
        $slot = @($slots | Where-Object { (Get-PASUISlotValue $S $_ 'Address') -eq $address }) | Select-Object -First 1
        $password = $null
        if ($slot) {
            $password = Get-PASUITypedSecret ('srv-' + [string]$slot.Key + '-pass')
        }
        if (-not $password) {
            throw "Enter the password for: $($requirement.Label)"
        }
        $credentials[$key] = New-Object pscredential ((Get-PASUISlotValue $S $slot 'User'), $password)
    }
    return @{ Credentials = $credentials; Secrets = $secrets }
}

# ------------------------------------------------------------------ dialogs

function Show-PASUIDialog {
    param([string]$Title, [string]$Text, [string]$Yes)
    $ui.DialogTitle.Text = $Title
    $ui.DialogText.Text = $Text
    $ui.DialogYes.Content = $Yes
    $ui.Main.IsEnabled = $false
    $ui.DialogYes.IsDefault = $true
    $ui.DialogNo.IsCancel = $true
    $ui.Overlay.Visibility = 'Visible'
    if ($DialogBoxes.Count) {
        [void]$DialogBoxes[0].Focus()
    } else {
        [void]$ui.DialogYes.Focus()
    }
}

function Close-PASUIDialog {
    $ui.Overlay.Visibility = 'Collapsed'
    $ui.DialogYes.IsDefault = $false
    $ui.DialogNo.IsCancel = $false
    foreach ($box in @($DialogBoxes)) {
        $box.Clear()
    }
    $DialogBoxes.Clear()
    $ui.DialogFields.Children.Clear()
    $ui.DialogHint.Visibility = 'Collapsed'
    $ui.Main.IsEnabled = $true
}

function Show-PASUIConfirm {
    # Asks a yes/no question. $Action runs when the user confirms.
    param([string]$Title, [string]$Text, [string]$Yes, [scriptblock]$Action)
    $S.Pending = $Action
    $S.DialogRequirements = @()
    Show-PASUIDialog $Title $Text $Yes
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
    $DialogBoxes.Clear()
    $ui.DialogFields.Children.Clear()
    foreach ($requirement in @($Requirements)) {
        $box = New-Object Windows.Controls.PasswordBox
        [Windows.Automation.AutomationProperties]::SetName($box, [string]$requirement.Label)
        [void]$DialogBoxes.Add($box)
        [void]$ui.DialogFields.Children.Add((New-PASUIField ([string]$requirement.Label) $box -Margin '0,0,0,8'))
    }
    $ui.DialogHint.Visibility = 'Visible'
    Show-PASUIDialog $Title $Text 'Continue'
}

function Submit-PASUIDialog {
    # The dialog was confirmed: close it and run what was waiting, for the accounts dialog with what was typed.
    $action = $S.Pending
    $requirements = @($S.DialogRequirements)
    $S.Pending = $null
    $S.DialogRequirements = @()
    if (-not $requirements.Count) {
        Close-PASUIDialog
        if ($action) {
            & $action
        }
        return
    }
    $credentials = @{}
    $secrets = @{}
    $missing = $false
    for ($index = 0; $index -lt $requirements.Count; $index++) {
        $requirement = $requirements[$index]
        if (-not $DialogBoxes[$index].SecurePassword.Length) {
            $missing = $true
            continue
        }
        $secure = $DialogBoxes[$index].SecurePassword.Copy()
        $secure.MakeReadOnly()
        if ([string]$requirement.Kind -eq 'Secret') {
            $secrets[[string]$requirement.Key] = $secure
        } else {
            $credentials[[string]$requirement.Key] = New-Object pscredential ([string]$requirement.User, $secure)
        }
    }
    Close-PASUIDialog
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

function Select-PASUIFile {
    # Asks for a file to open or to save, or (Kind Folder) for a folder. Returns the path, or '' when cancelled.
    param([ValidateSet('Open', 'Save', 'Folder')][string]$Kind, [string]$Title, [string]$Filter = '', [string]$FileName = '')
    if ($Kind -eq 'Folder') {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $Title
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
            return ''
        }
        return [string]$dialog.SelectedPath
    }
    if ($Kind -eq 'Open') {
        $dialog = New-Object Microsoft.Win32.OpenFileDialog
    } else {
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.FileName = $FileName
    }
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    if ($S.StartDirectory -and (Test-Path -LiteralPath $S.StartDirectory -PathType Container)) {
        $dialog.InitialDirectory = [string]$S.StartDirectory
    }
    if (-not $dialog.ShowDialog($window)) {
        return ''
    }
    return [string]$dialog.FileName
}

# ------------------------------------------------------------------ installer calls

function Get-PASUIPlanArguments {
    # The entries of the window as the parameters of New-PASLabConfiguration.
    $arguments = @{
        Environment = ([string]$S.LabName).Trim()
        VaultMode = [string]$S.VaultMode
        Instances = @(Get-PASUIInstances $S)
        ControllerAddress = ([string]$S.Controller).Trim()
        Username = 'Administrator'
        LinuxUsername = 'root'
        Media = $S.MediaSelection
        SecurityProfile = 'Lab'
        InstallerName = ([string]$S.InstallerName).Trim()
        InstallerCompany = ([string]$S.InstallerCompany).Trim()
    }
    $domainSlot = Get-PASUIDomainSlot $S
    if ($domainSlot) {
        $arguments.DomainMode = [string]$S.Domain
        $arguments.DomainName = ([string]$S.DomainName).Trim()
        $arguments.DomainControllerAddress = Get-PASUISlotValue $S $domainSlot 'Address'
        $arguments.DomainUsername = Get-PASUISlotValue $S $domainSlot 'User'
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
    return $arguments
}

function Start-PASUIPlan {
    # Has the installer build the configuration from the entries, validate it and lay out the plan, in the
    # background. Fills $S.Configuration, $S.Check, $S.Plan and $S.Requirements, then runs $Then. Contacts no server.
    param([scriptblock]$Then)
    $S.Configuration = $null
    $S.Plan = $null
    $S.Requirements = @()
    $S.AfterPlan = $Then
    Start-PASUITask -ArgumentList @(, (Get-PASUIPlanArguments)) -ScriptBlock {
        param([hashtable]$Arguments)
        $configuration = New-PASLabConfiguration @Arguments
        $check = Test-PASLabConfiguration -Configuration $configuration -CheckMedia
        $plan = $null
        $requirements = @()
        if ($check.Valid) {
            $plan = Get-PASLabPlan -Configuration $configuration
            $requirements = @(Get-PASCredentialRequirement -Configuration $configuration)
        }
        @{ Configuration = $configuration; Valid = [bool]$check.Valid; Issues = @($check.Issues); Warnings = @($check.Warnings); Plan = $plan; Requirements = $requirements }
    } -OnCompleted {
        param($result)
        $answer = @($result)[-1]
        $S.Check = @{ Valid = [bool]$answer.Valid; Issues = @($answer.Issues); Warnings = @($answer.Warnings) }
        $S.Configuration = $answer.Configuration
        $S.Plan = $answer.Plan
        $S.Requirements = @($answer.Requirements)
        $then = $S.AfterPlan
        $S.AfterPlan = $null
        & $then
    } -OnFailed {
        param($failure)
        $S.Check = @{ Valid = $false; Issues = @([string]$failure.Message); Warnings = @() }
        $then = $S.AfterPlan
        $S.AfterPlan = $null
        & $then
    }
}

function Invoke-PASUIMediaScan {
    # Looks for installers in the media folder and in what was dropped, in the background. $Then runs afterwards.
    param([scriptblock]$Then = $null)
    $paths = @(Get-PASUIMediaPaths $S)
    if (-not $paths.Count) {
        throw 'Type, choose or drop the media folder first.'
    }
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "This does not exist: $path"
        }
    }
    if ($S.Scanning) {
        return
    }
    $S.Scanning = $true
    $S.AfterScan = $Then
    Set-PASUINotice 'busy' 'Looking for installers...'
    Start-PASUITask -ArgumentList @(, $paths) -ScriptBlock {
        param([string[]]$Paths)
        $items = @(Get-PASMediaInventory -Path $Paths)
        $selection = @{}
        if ($items.Count) {
            $selection = Get-PASMediaSelection -Inventory $items
        }
        @{ Items = $items; Selection = $selection }
    } -OnCompleted {
        param($result)
        $answer = @($result)[-1]
        $S.Scanning = $false
        $S.MediaItems = @($answer.Items)
        $S.MediaSelection = $answer.Selection
        $S.MediaScanned = $true
        Set-PASUINotice
        if ($S.Screen -eq 'media') {
            Show-PASUIMediaResult
        }
        $then = $S.AfterScan
        $S.AfterScan = $null
        if ($then) {
            & $then
        }
    } -OnFailed {
        param($failure)
        $S.Scanning = $false
        $S.AfterScan = $null
        Set-PASUINotice 'error' ('The media could not be read: ' + [string]$failure.Message)
    }
}

function Start-PASUIServerCheck {
    # "Next" on the Servers step. The window says at once that it is checking and stays usable: everything
    # runs in the background. First the plan is laid out from the entries. Part 1, within seconds: does every
    # server answer at all? Part 2: sign in to each one and check that it is ready. Only when everything
    # passed the review step is shown.
    $S.Preflight = $null
    Show-PASUIServerCheckPhase 'plan'
    Start-PASUIPlan {
        if (-not $S.Check.Valid) {
            Show-PASUIServerCheckPhase ''
            Set-PASUIRegion 'ServersIssues' @((New-PASUIIssueBox @($S.Check.Issues) 'The plan has problems'))
            return
        }
        try {
            $S.CheckAccounts = Get-PASUIFormAccounts
        } catch {
            Show-PASUIServerCheckPhase ''
            throw
        }
        Start-PASUIServerCheckPart 'reach'
    }
}

function Start-PASUIServerCheckPart {
    # Runs one part of the server check in the background: 'reach' or 'signin'.
    param([string]$Phase)
    Show-PASUIServerCheckPhase $Phase
    $credentials = $null
    if ($Phase -eq 'signin') {
        $credentials = $S.CheckAccounts.Credentials
    }
    Start-PASUITask -ArgumentList @($S.Configuration, $credentials) -ScriptBlock {
        param($Configuration, [hashtable]$CredentialMap)
        if ($CredentialMap) {
            Test-PASPreflight -Configuration $Configuration -CredentialMap $CredentialMap
        } else {
            Test-PASPreflight -Configuration $Configuration -ConnectivityOnly
        }
    } -OnCompleted {
        param($result)
        # One part is done. After part 1 without a problem, part 2 follows; otherwise the result is shown.
        $rows = @($result)
        $problems = @($rows | Where-Object { $_.Passed -is [bool] -and -not $_.Passed }).Count
        if ([string]$S.CheckPhase -eq 'reach' -and -not $problems) {
            Start-PASUIServerCheckPart 'signin'
            return
        }
        $S.CheckAccounts = $null
        $S.Preflight = $rows
        Show-PASUIServerCheckPhase ''
        if ($S.Screen -ne 'servers') {
            return
        }
        if ($problems) {
            $ui.Page.ScrollToEnd()
            return
        }
        Show-PASUIScreen 'review'
    } -OnFailed {
        param($failure)
        $S.CheckAccounts = $null
        Show-PASUIServerCheckPhase ''
        Set-PASUINotice 'error' ('The servers could not be checked: ' + [string]$failure.Message)
    }
}

function Show-PASUIServerCheckPhase {
    # Shows which part of the server check is running: 'plan', 'reach', 'signin', or '' when none is.
    param([string]$Phase)
    $S.Checking = [bool]$Phase
    $S.CheckPhase = $Phase
    # Also in the line at the top, which is in view wherever the page is scrolled to.
    switch ($Phase) {
        'plan' { Set-PASUINotice 'busy' 'Checking the servers...' }
        'reach' { Set-PASUINotice 'busy' 'Checking the servers: looking whether they answer...' }
        'signin' { Set-PASUINotice 'busy' 'Checking the servers: signing in to each one...' }
        default { Set-PASUINotice }
    }
    if ($S.Screen -eq 'servers') {
        Show-PASUIPreflight
        Show-PASUIBar
        if ($Phase -eq 'plan') {
            $ui.Page.ScrollToEnd()
        }
    }
}

function Start-PASUIInstall {
    # Starts the installation in the background, so that the window stays usable for the half minute the
    # installer needs to check the plan and start its own process.
    if ($S.Starting) {
        return
    }
    $accounts = Get-PASUIFormAccounts
    $S.Starting = $accounts
    Set-PASUINotice 'busy' 'Starting the installation...'
    if ($R.ContainsKey('InstallButton')) {
        $R['InstallButton'].IsEnabled = $false
    }
    Start-PASUITask -ArgumentList @($S.Configuration, $accounts.Credentials, $accounts.Secrets) -ScriptBlock {
        param($Configuration, [hashtable]$CredentialMap, [hashtable]$SecretMap)
        Install-PASLab -Configuration $Configuration -CredentialMap $CredentialMap -SecretMap $SecretMap -Confirm:$false
    } -OnCompleted {
        param($result)
        $runId = [string](@($result)[-1])
        $accounts = $S.Starting
        $S.Starting = $null
        if ($runId -notmatch '^[0-9a-fA-F]{32}$') {
            if ($R.ContainsKey('InstallButton')) {
                $R['InstallButton'].IsEnabled = $true
            }
            throw "The installation was not started: the installer returned no run id ($runId)."
        }
        # The installer process has the passwords now. The window keeps them only as protected objects, for
        # "Try again" and "Check the lab", until it is closed. What was typed is forgotten.
        $S.Kept = @{ RunId = $runId; Credentials = $accounts.Credentials; Secrets = $accounts.Secrets }
        Clear-PASUIPasswords
        $S.Preflight = $null
        $S.RunPlan = @{}
        foreach ($item in @($S.Plan.Items)) {
            $S.RunPlan[[string]$item.Id] = @{ Address = [string]$item.Address }
        }
        Set-PASUINotice
        Open-PASUIRun $runId
    } -OnFailed {
        param($failure)
        $S.Starting = $null
        if ($R.ContainsKey('InstallButton')) {
            $R['InstallButton'].IsEnabled = $true
        }
        Set-PASUINotice 'error' ('The installation was not started: ' + [string]$failure.Message)
    }
}

function Open-PASUIRun {
    # Shows the page of one installation and keeps it up to date while it runs.
    param([string]$RunId)
    if ($S.RunId -ne $RunId) {
        $S.Health = $null
        $S.LogOpen = $false
    }
    $S.RunId = $RunId
    $S.Opening = $true
    Start-PASUITask -ArgumentList @($RunId) -ScriptBlock {
        param([string]$RunId)
        Get-PASRun -RunId $RunId -Tail 1000
    } -OnCompleted {
        param($result)
        $S.Opening = $false
        $S.Run = @($result)[-1]
        $S.RunSignature = Get-PASUIRunSignature
        if ($S.Notice -and [string]$S.Notice.Kind -eq 'busy') {
            Set-PASUINotice
        }
        Show-PASUIScreen 'run'
    } -OnFailed {
        param($failure)
        $S.Opening = $false
        Set-PASUINotice 'error' ('This installation could not be read: ' + [string]$failure.Message)
    }
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
    # Reads the installation again, in the background, and fills the parts of its page that show it.
    if ($S.Screen -ne 'run' -or -not $S.RunId -or $S.Polling) {
        return
    }
    $S.Polling = $true
    Start-PASUITask -ArgumentList @([string]$S.RunId) -ScriptBlock {
        param([string]$RunId)
        Get-PASRun -RunId $RunId -Tail 1000
    } -OnCompleted {
        param($result)
        $S.Polling = $false
        $snapshot = @($result)[-1]
        if ($S.Screen -ne 'run' -or [string]$snapshot.RunId -ne [string]$S.RunId) {
            return
        }
        $S.Run = $snapshot
        $signature = Get-PASUIRunSignature
        if ($signature -eq $S.RunSignature) {
            return
        }
        $S.RunSignature = $signature
        if ($S.ResumeUntil -and (Test-PASUIRunActive ([string]$S.Run.Status))) {
            # The installer process has the installation again.
            $S.ResumeUntil = $null
            Set-PASUINotice
        }
        Show-PASUIRunParts
    } -OnFailed {
        param($failure)
        $S.Polling = $false
    }
}

function Test-PASUIRunWatched {
    # Is there an installation on screen that can still change? After "continue" it still reads as stopped
    # for a few seconds, until the installer process has taken it over again: keep looking for a while.
    if ($S.Screen -ne 'run' -or -not $S.Run) {
        return $false
    }
    if (Test-PASUIRunActive ([string]$S.Run.Status)) {
        return $true
    }
    return [bool]($S.ResumeUntil -and [datetime]::UtcNow -lt $S.ResumeUntil)
}

function Resume-PASUIRun {
    # Continues a stopped installation, in the background; -RetryStep repeats the step that failed.
    param([hashtable]$Accounts, [string]$RetryStep = '')
    $arguments = @{ RunId = [string]$S.RunId; CredentialMap = $Accounts.Credentials; SecretMap = $Accounts.Secrets }
    if ($RetryStep) {
        $arguments.RetryStep = @($RetryStep)
    }
    Set-PASUINotice 'busy' 'Continuing the installation...'
    Start-PASUITask -ArgumentList @(, $arguments) -ScriptBlock {
        param([hashtable]$Arguments)
        $null = Resume-PASRun @Arguments -Confirm:$false
    } -OnCompleted {
        $S.ResumeUntil = [datetime]::UtcNow.AddSeconds(90)
        $S.Health = $null
        Set-PASUINotice 'info' 'The installation continues. Finished steps are checked again first; this page updates by itself.'
        $S.RunSignature = ''
        Update-PASUIRun
    } -OnFailed {
        param($failure)
        Set-PASUINotice 'error' ('The installation was not continued: ' + [string]$failure.Message)
    }
}

function Invoke-PASUIHealth {
    # "Check the lab": asks the Vault through PVWA which components are connected, in the background.
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
    Start-PASUITask -ArgumentList @(, $arguments) -ScriptBlock {
        param([hashtable]$Arguments)
        Test-PASHealth @Arguments
    } -OnCompleted {
        param($result)
        $S.Health = @($result)[-1]
        Set-PASUINotice
        if ($S.Screen -eq 'run') {
            Show-PASUIRunStatus
        }
    } -OnFailed {
        param($failure)
        if ([string]$failure.Message -match 'configuration has no PVWA') {
            Set-PASUINotice 'error' 'This installation has no PVWA of its own, and the lab check asks the Vault through PVWA. Check the lab from the installation that has the PVWA.'
            return
        }
        Set-PASUINotice 'error' ('The lab could not be checked: ' + [string]$failure.Message)
    }
}

function Open-PASUILabFile {
    # Fills the choices from a saved lab file, read in the background. Media and passwords are not in it.
    param([string]$Path)
    Set-PASUINotice 'busy' 'Opening the lab file...'
    Start-PASUITask -ArgumentList @($Path) -ScriptBlock {
        param([string]$Path)
        $configuration = Import-PASLabConfiguration -Path $Path
        @{ Configuration = $configuration; Plan = (Get-PASLabPlan -Configuration $configuration) }
    } -OnCompleted {
        param($result)
        $answer = @($result)[-1]
        Set-PASUILabFromFile $answer.Configuration $answer.Plan
        Set-PASUINotice 'info' 'Lab file opened. Choose the media folder again; passwords are never stored in a lab file.'
        Show-PASUIScreen 'media'
    } -OnFailed {
        param($failure)
        Set-PASUINotice 'error' ('The lab file could not be opened: ' + [string]$failure.Message)
    }
}

function Set-PASUILabFromFile {
    # The choices of a saved lab, from its configuration and plan.
    param($Configuration, $Plan)
    $S.LabName = [string]$Configuration['name']
    $S.Preset = 'custom'
    $S.Slots = @{}
    $types = @($Plan.Items | ForEach-Object { [string]$_.Type })
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
    $pvwaAddresses = @($Plan.Items | Where-Object { [string]$_.Type -eq 'PVWA' } | ForEach-Object { [string]$_.Address })
    $cpmAddresses = @($Plan.Items | Where-Object { [string]$_.Type -eq 'CPM' } | ForEach-Object { [string]$_.Address })
    $S.Colocate = [bool]@($cpmAddresses | Where-Object { $pvwaAddresses -contains $_ }).Count -or -not $cpmAddresses.Count
    $numbers = @{}
    foreach ($item in @($Plan.Items)) {
        $type = [string]$item.Type
        $account = [string]$Configuration['hosts'][[string]$item.Host]['user']
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
        $S.ExistingVault = [string]$Configuration['vault']['address']
    }
}

function Show-PASUIHome {
    # The start page; the list of installations is read in the background.
    $S.RunsLoading = $true
    Show-PASUIScreen 'home'
    Start-PASUITask -ScriptBlock {
        Get-PASRun
    } -OnCompleted {
        param($result)
        $S.RunsLoading = $false
        $S.Runs = @($result | Where-Object { $_ })
        if ($S.Screen -eq 'home') {
            Show-PASUIRunList
        }
    } -OnFailed {
        param($failure)
        $S.RunsLoading = $false
        $S.Runs = @()
        if ($S.Screen -eq 'home') {
            Show-PASUIRunList
        }
        Set-PASUINotice 'error' ('The earlier installations could not be read: ' + [string]$failure.Message)
    }
}

# ------------------------------------------------------------------ events

function Invoke-PASUIClick {
    # A button was pressed: $Id is its id.
    param([string]$Id)
    switch -Regex ($Id) {
        '^nav-home$' {
            Set-PASUINotice
            Show-PASUIHome
            return
        }
        '^act-new$' {
            Show-PASUIScreen 'media'
            return
        }
        '^act-open$' {
            $path = Select-PASUIFile -Kind Open -Title 'Open a lab file' -Filter 'Lab files (*.json)|*.json'
            if ($path) {
                Open-PASUILabFile $path
            }
            return
        }
        '^act-browse$' {
            $path = Select-PASUIFile -Kind Folder -Title 'Folder with the CyberArk installer media'
            if (-not $path) {
                return
            }
            $S.MediaPath = $path
            if ($R.ContainsKey('MediaPathBox')) {
                $R['MediaPathBox'].Text = $path
            }
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
            if ($position -eq 1) {
                Set-PASUINotice
                Show-PASUIHome
            } elseif ($position -gt 1) {
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
        '^domain-(None|New|Existing)$' {
            $S.Domain = $Matches[1]
            Show-PASUIScreen 'lab'
            return
        }
        '^cnt-(PVWA|CPM|PSM|PSMP|HTML5GW|PTA)-(inc|dec)$' {
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
            $path = Select-PASUIFile -Kind Save -Title 'Save the lab file' -Filter 'Lab files (*.json)|*.json' -FileName ("PASeasyInstall-$($S.LabName).json")
            if (-not $path) {
                return
            }
            Start-PASUITask -ArgumentList @($S.Configuration, $path) -ScriptBlock {
                param($Configuration, [string]$Path)
                Export-PASLabConfiguration -Configuration $Configuration -Path $Path -Force
            } -OnCompleted {
                param($result)
                Set-PASUINotice 'ok' ('Saved: ' + [string](@($result)[-1]))
            }
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
            Set-PASUINotice 'busy' 'Opening the installation...'
            Open-PASUIRun $Matches[1]
            return
        }
        '^act-log$' {
            $S.LogOpen = -not $S.LogOpen
            Show-PASUIRunLog
            return
        }
        '^act-retry$' {
            $failure = Get-PASUIFailure $S.Run
            $S.RetryStep = [string]$failure.RetryStep
            Request-PASUIAccounts 'Try this step again' 'The accounts are needed again to continue the installation.' (Get-PASUIRunRequirements) {
                param($accounts)
                Resume-PASUIRun -Accounts $accounts -RetryStep ([string]$S.RetryStep)
            }
            return
        }
        '^act-resume$' {
            Request-PASUIAccounts 'Continue the installation' 'The accounts are needed again to continue the installation.' (Get-PASUIRunRequirements) {
                param($accounts)
                Resume-PASUIRun -Accounts $accounts
            }
            return
        }
        '^act-health$' {
            Request-PASUIAccounts 'Check the lab' 'The lab check signs in to the Vault through PVWA.' (Get-PASUIRunRequirements -Only @('VaultAdmin', 'dr01')) {
                param($accounts)
                Invoke-PASUIHealth -Accounts $accounts
            }
            return
        }
        '^act-diag$' {
            $path = Select-PASUIFile -Kind Save -Title 'Save the logs' -Filter 'ZIP (*.zip)|*.zip' -FileName ("PASeasyInstall-logs-$(([string]$S.RunId).Substring(0, 8)).zip")
            if ($path) {
                Export-PASUILogs $path
            }
            return
        }
        '^act-stop$' {
            Show-PASUIConfirm 'Stop the installation?' 'The step that is running on the server is not interrupted, but nothing new is started. You can continue the installation later.' 'Stop' {
                Start-PASUITask -ArgumentList @([string]$S.RunId) -ScriptBlock {
                    param([string]$RunId)
                    $null = Stop-PASRun -RunId $RunId -Confirm:$false
                } -OnCompleted {
                    $S.RunSignature = ''
                    Update-PASUIRun
                }
            }
            return
        }
        '^dlg-yes$' {
            Submit-PASUIDialog
            return
        }
        '^dlg-no$' {
            $S.Pending = $null
            $S.DialogRequirements = @()
            Close-PASUIDialog
            return
        }
    }
}

function Export-PASUILogs {
    # Saves the logs of the installation on screen as a ZIP, in the background.
    param([string]$Path)
    Set-PASUINotice 'busy' 'Collecting the logs...'
    Start-PASUITask -ArgumentList @([string]$S.RunId, $Path) -ScriptBlock {
        param([string]$RunId, [string]$Path)
        $null = Export-PASDiagnostics -RunId $RunId -Path $Path -Force
        $Path
    } -OnCompleted {
        param($result)
        Set-PASUINotice 'ok' ('Logs saved: ' + [string](@($result)[-1]) + '. Passwords are not part of them.')
    } -OnFailed {
        param($failure)
        Set-PASUINotice 'error' ('The logs could not be saved: ' + [string]$failure.Message)
    }
}

function Invoke-PASUINext {
    # Next on the bottom bar: the step must be complete, then the following screen is drawn.
    switch ([string]$S.Screen) {
        'media' {
            if (-not $S.MediaScanned -and @(Get-PASUIMediaPaths $S).Count) {
                Invoke-PASUIMediaScan -Then {
                    if ($S.Screen -eq 'media' -and (Show-PASUIIssues 'media')) {
                        Show-PASUIScreen 'lab'
                    }
                }
                return
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
        '^f-labname$' {
            $S.LabName = $Value
            return
        }
        '^f-existing$' {
            $S.ExistingVault = $Value
            return
        }
        '^f-domainname$' {
            $S.DomainName = $Value
            return
        }
        '^f-controller$' {
            $S.Controller = $Value
            return
        }
        '^f-installer-name$' {
            $S.InstallerName = $Value
            return
        }
        '^f-vault-timezone$' {
            $S.VaultTimezone = $Value
            return
        }
        '^f-installer-company$' {
            $S.InstallerCompany = $Value
            return
        }
        '^srv-([a-z0-9]+)-name$' {
            Set-PASUISlotValue $S $Matches[1] 'Name' $Value
            return
        }
        '^srv-([a-z0-9]+)-user$' {
            Set-PASUISlotValue $S $Matches[1] 'User' $Value
            return
        }
        '^srv-([a-z0-9]+)-addr$' {
            Set-PASUISlotValue $S $Matches[1] 'Address' $Value
            $S.Preflight = $null
            return
        }
    }
}

function Set-PASUIToggle {
    # A check box or the Advanced switch changed.
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

$ui.NavHome.Add_Click({ Invoke-PASUISafe { Invoke-PASUIClick 'nav-home' } })
$ui.BtnBack.Add_Click({ Invoke-PASUISafe { Invoke-PASUIClick 'act-back' } })
$ui.BtnNext.Add_Click({ Invoke-PASUISafe { Invoke-PASUIClick 'act-next' } })
$ui.DialogYes.Add_Click({ Invoke-PASUISafe { Invoke-PASUIClick 'dlg-yes' } })
$ui.DialogNo.Add_Click({ Invoke-PASUISafe { Invoke-PASUIClick 'dlg-no' } })
$ui.NavHome.Tag = 'nav-home'
$ui.BtnBack.Tag = 'act-back'
$ui.BtnNext.Tag = 'act-next'
$ui.DialogYes.Tag = 'dlg-yes'
$ui.DialogNo.Tag = 'dlg-no'
$ui.OptAdvanced.Tag = 'opt-advanced'
# Checked and Unchecked also come when Show-PASUIScreen sets the switch to what the state says: nothing to do then.
$advancedChanged = {
    if ([bool]$ui.OptAdvanced.IsChecked -ne [bool]$S.Advanced) {
        Invoke-PASUISafe { Set-PASUIToggle 'opt-advanced' ([bool]$ui.OptAdvanced.IsChecked) }
    }
}
$ui.OptAdvanced.Add_Checked($advancedChanged)
$ui.OptAdvanced.Add_Unchecked($advancedChanged)

# Files and folders dropped from Explorer onto the media step.
$window.AllowDrop = $true
$window.Add_DragOver({
        param($sender, $eventArgs)
        $eventArgs.Effects = [Windows.DragDropEffects]::None
        if ($S.Screen -eq 'media' -and $eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
            $eventArgs.Effects = [Windows.DragDropEffects]::Copy
        }
        $eventArgs.Handled = $true
    })
$window.Add_Drop({
        param($sender, $eventArgs)
        if ($S.Screen -ne 'media' -or -not $eventArgs.Data.GetDataPresent([Windows.DataFormats]::FileDrop)) {
            return
        }
        $paths = @($eventArgs.Data.GetData([Windows.DataFormats]::FileDrop) | ForEach-Object { [string]$_ })
        Invoke-PASUISafe { Add-PASUIDroppedMedia $paths }
    })

function Add-PASUIDroppedMedia {
    # Takes over what was dropped on the media step and looks for installers in it.
    param([string[]]$Paths)
    if (-not $Paths.Count) {
        return
    }
    $folders = @($Paths | ForEach-Object { [bool](Test-Path -LiteralPath $_ -PathType Container) })
    Add-PASUIMediaDrop -State $S -Paths $Paths -IsFolder $folders
    Show-PASUIScreen 'media'
    Invoke-PASUIMediaScan
}

# While a running installation is on screen, it is read again every two seconds.
$PollTimer = New-Object Windows.Threading.DispatcherTimer
$PollTimer.Interval = [TimeSpan]::FromSeconds(2)
$PollTimer.Add_Tick({
        if (Test-PASUIRunWatched) {
            Invoke-PASUISafe { Update-PASUIRun }
        }
    })

# Last line of defence: an exception that escaped a handler is shown, not fatal.
$window.Dispatcher.Add_UnhandledException({
        param($sender, $eventArgs)
        $eventArgs.Handled = $true
        Set-PASUINotice 'error' ([string]$eventArgs.Exception.Message)
    })

# ------------------------------------------------------------------ run

$TestFailures = 0
if ($SelfTest) {
    . (Join-Path $PSScriptRoot 'SelfTest.ps1')
}
$window.Add_ContentRendered({
        if ($script:PASUIStarted) {
            return
        }
        $script:PASUIStarted = $true
        $PollTimer.Start()
        if ($SelfTest) {
            $null = $window.Dispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::ApplicationIdle, [Action]{
                    $script:TestFailures = Invoke-PASUISelfTest -ScenarioPath $SelfTest
                    $window.Close()
                })
            return
        }
        if ($Config) {
            Invoke-PASUISafe { Open-PASUILabFile $Config }
        }
    })
try {
    Show-PASUIHome
    $null = $window.ShowDialog()
} finally {
    $PollTimer.Stop()
    Stop-PASUITasks
}
if ($TestFailures) {
    exit 1
}
