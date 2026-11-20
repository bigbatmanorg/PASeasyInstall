# Entry script of the detached run controller process. Start-PASDeployment and Resume-PASDeployment
# start it with: powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File <this file> ...
# It loads the module and runs the controller inside the module scope (the controller is not exported).
[CmdletBinding()]
param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$DataRoot,
      [Parameter(Mandatory)][string]$Envelope,[switch]$Resume,[switch]$RetryFailedPreflight,
      # Step ids the operator wants executed again (Resume-PASDeployment -RetryStep), comma-separated.
      [string]$RetryStep='')
$ErrorActionPreference='Stop'
try {
    $module = Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall.psd1') -Force -PassThru
    $retrySteps = @($RetryStep -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    & $module {
        param($id,$root,$credentialEnvelope,$resumeRun,$retryPreflight,$steps)
        Invoke-PASRunController -RunId $id -DataRoot $root -Envelope $credentialEnvelope -Resume:$resumeRun -RetryFailedPreflight:$retryPreflight -RetryStep $steps
    } $RunId $DataRoot $Envelope ([bool]$Resume) ([bool]$RetryFailedPreflight) $retrySteps
} catch {
    $message = [string]$_.Exception.Message
    # The controller normally records its own outcome. If it could not (for example the module failed to
    # load), put the real error into the run record. Never write over another live controller: a second
    # launcher that lost the race for the run lock ends here too.
    try {
        $recordPath = Join-Path (Join-Path (Join-Path $DataRoot 'Runs') $RunId) 'run.json'
        if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
            $record = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
            $owner = 0
            if ($record.controllerPid) { $owner = [int]$record.controllerPid }
            if ($owner -eq $PID) {
                # This process claimed the run; the controller records every outcome except a crash.
                $write = ([string]$record.status -in @('Launching','Running'))
            } else {
                # A previous controller's record (resume) or none yet: only when that process is gone.
                $write = (-not $owner -or -not (Get-Process -Id $owner -ErrorAction SilentlyContinue))
            }
            if ($write) {
                $record.status = 'LaunchFailed'
                $record.message = 'Deployment controller stopped: ' + $message
                $record.finishedUtc = [DateTime]::UtcNow.ToString('o')
                [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
            }
        }
    } catch {
        Write-Error ('Could not record the controller failure: ' + $_.Exception.Message) -ErrorAction Continue
    }
    Write-Error ('Deployment controller stopped: ' + $message) -ErrorAction Continue
    exit 1
} finally {
    if(Test-Path -LiteralPath $Envelope){Remove-Item -LiteralPath $Envelope -Force -ErrorAction SilentlyContinue}
}
