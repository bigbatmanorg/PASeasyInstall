function Resume-PASRun {
    <#
    .SYNOPSIS
    Continues a run that stopped: finished components are checked again, the remaining ones are installed.
    .DESCRIPTION
    Works on a run whose status is Failed, Unknown, Interrupted, LaunchFailed or Blocked. The run keeps
    its own copy of the configuration and its plan; they are used again unchanged, and so must the
    installer media be.

    What happens on resume:
    - steps that finished are verified again, not repeated;
    - a step that was still running on a server is picked up where it is, never started a second time;
    - a step that ended Failed or Unknown is NOT repeated on its own. Look at the server and at
      Get-PASRunEvent -Failed, correct the cause, then name the step with -RetryStep.

    The command checks the run and asks for confirmation. Only then it asks for the server accounts and
    passwords of the run's configuration that -CredentialMap, -SecretMap or -LabPassword do not supply
    (passwords are never stored, so they are needed again). With -WhatIf nothing is asked.
    .PARAMETER RunId
    Run id (32 hexadecimal characters).
    .PARAMETER RetryStep
    Steps to execute again, as '<step>' or '<component>:<step>', e.g. 'install' or 'cpm01:register'.
    Only steps that ended Failed or Unknown are accepted. Get-PASStageCatalog lists the step names.
    .PARAMETER RetryFailedPreflight
    Runs a failed read-only preflight of a Linux server again, for example after you installed a
    missing package there.
    .PARAMETER CredentialMap
    Server accounts: @{ <server id> = PSCredential }. Missing ones are asked for.
    .PARAMETER SecretMap
    Passwords as SecureString: @{ VaultAdmin = ...; VaultMaster = ...; DRPassword = ...;
    ADSafeMode = ...; DomainJoinPassword = ... }. Missing ones are asked for.
    .PARAMETER LabPassword
    One password for every server and every secret that is not supplied otherwise. Only for a run
    with the Lab security profile.
    .PARAMETER Wait
    Shows the progress until the run ends and returns the final run (see Wait-PASRun).
    .PARAMETER PollSeconds
    With -Wait: seconds between two progress checks. Default 15.
    .EXAMPLE
    Resume-PASRun -RunId 688d8e04f1874d41a75cda4441c00553 -Wait

    Asks for the accounts and passwords again, continues the run and shows the progress.
    .EXAMPLE
    Resume-PASRun -RunId $id -RetryStep 'pvwa01:install' -LabPassword $lab

    Continues a lab run and executes the failed install step of pvwa01 again.
    .EXAMPLE
    Get-PASRun -Last 1 | Resume-PASRun -RetryFailedPreflight -Wait
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [ValidatePattern('^[0-9a-fA-F]{32}$')]
        [string]$RunId,

        [string[]]$RetryStep = @(),

        [switch]$RetryFailedPreflight,

        [hashtable]$CredentialMap = @{},

        [hashtable]$SecretMap = @{},

        [securestring]$LabPassword,

        [switch]$Wait,

        [ValidateRange(1, 600)]
        [int]$PollSeconds = 15
    )

    process {
        $id = $RunId.ToLowerInvariant()
        $record = Get-PASRunRecord -RunId $id
        if (-not $record) {
            throw "Run $id was not found under $(Get-PASDataRoot). Get-PASRun lists the runs of this controller."
        }
        $status = [string]$record.status
        if ($status -in @('Launching', 'Running')) {
            throw "Run $id is still running. Follow it with Wait-PASRun -RunId $id."
        }
        if ($status -eq 'Succeeded') {
            throw "Run $id succeeded; there is nothing to resume."
        }
        if ($status -eq 'Abandoned') {
            throw "Run $id was stopped with Stop-PASRun and cannot be resumed. Start a new run with the same configuration."
        }

        # The run's own, frozen configuration tells which accounts and passwords it needs.
        $directory = Get-PASRunDirectory -RunId $id
        $configurationFile = Join-Path $directory 'config.json'
        if (-not (Test-Path -LiteralPath $configurationFile -PathType Leaf)) {
            throw "Run $id has no saved configuration ($configurationFile is missing) and cannot be resumed. Start a new run."
        }
        $configuration = Read-PASConfiguration -Path $configurationFile
        Assert-PASLabPassword $configuration $LabPassword

        # A wrong step name is reported now, before anything is asked.
        $steps = @($RetryStep | Where-Object { $_ })
        [void](Resolve-PASRetrySteps -RunDirectory $directory -RetryStep $steps)

        if (-not $PSCmdlet.ShouldProcess($id, "Resume the run of environment '$([string]$record.name)' (status $status)")) {
            return
        }
        Assert-PASWindowsController

        $auth = Resolve-PASInstallCredential -Configuration $configuration -CredentialMap $CredentialMap -SecretMap $SecretMap -LabPassword $LabPassword
        $resume = @{
            RunId                = $id
            CredentialMap        = $auth.Credentials
            SecretMap            = $auth.Secrets
            RetryStep            = $steps
            RetryFailedPreflight = $RetryFailedPreflight
            Confirm              = $false
        }
        [void](Resume-PASDeployment @resume)
        $auth = $null

        if ($Wait) {
            return (Wait-PASRun -RunId $id -PollSeconds $PollSeconds)
        }
        return $id
    }
}
