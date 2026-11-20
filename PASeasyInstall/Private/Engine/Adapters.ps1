$script:PSConnections = @{}
$script:PATaskHostText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Assets/TaskHost.ps1'))
$script:PATaskHostBlock = [scriptblock]::Create($script:PATaskHostText)

function New-PASUnknownError {
    param([string]$Message)
    return (New-Object System.Exception ('PAExecUnknown: ' + $Message))
}
function Get-PASConnection {
    param([hashtable]$Target,[hashtable]$Credentials)
    $protocol=[string]$Target.Protocol
    if ($protocol -ne 'WinRM') { return $null }
    if (-not (Test-PASWindows)) { return $null }
    $computer=[string]$Target.ComputerName
    $key=[string](Get-PASValue $Target 'CredentialRef' '')
    if (-not $Credentials.ContainsKey($key) -or $Credentials[$key] -isnot [pscredential]) { throw "WinRM target '$computer' requires PSCredential '$key'" }
    # ConfigurationName may be an ordered list: a preferred (e.g. restricted) endpoint, then fallbacks that are
    # used only when the preferred endpoint is not registered on the target (never on authentication errors).
    $configurations=@(@(Get-PASValue $Target 'ConfigurationName' @('')) | ForEach-Object { [string]$_ })
    if($configurations.Count -eq 0){$configurations=@('')}
    $fingerprint="$computer/$key/$([string](Get-PASValue $Target 'UseSSL' $false))/$($configurations -join '|')/$([string](Get-PASValue $Target 'Port' ''))"
    if ($script:PSConnections.ContainsKey($fingerprint)) {
        $session=$script:PSConnections[$fingerprint]
        if ($session.State -eq 'Opened' -and $session.Availability -eq 'Available') { return $session }
        try { Remove-PSSession $session -ErrorAction SilentlyContinue } catch { Write-Verbose 'Stale session cleanup failed' }
        $script:PSConnections.Remove($fingerprint)
    }
    $credentialRefs=@($key)
    $transition=[string](Get-PASValue $Target 'TransitionCredentialRef' '')
    if($transition){
        if(-not $Credentials.ContainsKey($transition) -or $Credentials[$transition] -isnot [pscredential]){throw 'Explicit domain-transition credential is required'}
        if($Credentials[$transition].UserName -ne $Credentials[$key].UserName){$credentialRefs+=$transition}
    }
    $credentialIndex=0
    $sessionArgs=@{ ComputerName=$computer; Credential=$Credentials[$key]; ErrorAction='Stop'; Authentication='Negotiate' }
    if ([bool](Get-PASValue $Target 'UseSSL' $false)) { $sessionArgs.UseSSL=$true }
    if ($Target.Contains('Port')) { $sessionArgs.Port=[int]$Target.Port }
    if ($Target.Contains('Authentication')) { $sessionArgs.Authentication=[string]$Target.Authentication }
    $optionArgs=@{ OpenTimeout=([int](Get-PASValue $Target 'OpenTimeoutSeconds' 30))*1000; OperationTimeout=([int](Get-PASValue $Target 'OperationTimeoutSeconds' 600))*1000 }
    if ([bool](Get-PASValue $Target 'SkipCACheck' $false)) { $optionArgs.SkipCACheck=$true }
    if ([bool](Get-PASValue $Target 'SkipCNCheck' $false)) { $optionArgs.SkipCNCheck=$true }
    $sessionArgs.SessionOption=New-PSSessionOption @optionArgs
    # A target can be briefly unreachable (installer rebinding HTTP.sys, reboot, service restart). Nothing has
    # been dispatched yet, so connecting is retried for ConnectRetrySeconds; authentication failures are final.
    $retryUntil=[DateTime]::UtcNow.AddSeconds([int](Get-PASValue $Target 'ConnectRetrySeconds' 600))
    $session=$null
    while ($null -eq $session) {
        try {
            for ($i=0; $i -lt $configurations.Count; $i++) {
                $attemptArgs=$sessionArgs.Clone()
                if ($configurations[$i]) { $attemptArgs.ConfigurationName=$configurations[$i] }
                try { $session=New-PSSession @attemptArgs; break }
                catch {
                    $missing=([string]$_.Exception.Message) -match 'Cannot find the .+ session configuration|session configuration .+ (was not found|is not found)'
                    if (-not $missing -or $i -eq $configurations.Count-1) { throw }
                    Write-Verbose "Endpoint '$($configurations[$i])' not registered on $computer; trying next"
                }
            }
        } catch {
            $text=[string]$_.Exception.Message
            if($text -match 'Access is denied|logon failure|user name or password|LogonUser failed'){
                if($credentialIndex+1 -lt $credentialRefs.Count){
                    $credentialIndex++
                    $sessionArgs.Credential=$Credentials[$credentialRefs[$credentialIndex]]
                    Write-Verbose 'Using explicitly configured post-promotion credential'
                    continue
                }
                throw
            }
            if([DateTime]::UtcNow -ge $retryUntil){throw}
            Write-Verbose "Connection to $computer failed ($text); retrying"
            Start-Sleep -Seconds 10
        }
    }
    $script:PSConnections[$fingerprint]=$session
    return $session
}
function Clear-PASConnections {
    foreach ($s in @($script:PSConnections.Values)) { try { Remove-PSSession $s -ErrorAction SilentlyContinue } catch { Write-Verbose 'Session cleanup failed' } }
    $script:PSConnections=@{}
}
function Test-PASTransportFailure {
    param($ErrorRecordOrException)
    $e = $ErrorRecordOrException
    if ($e -is [System.Management.Automation.ErrorRecord]) { $e = $e.Exception }
    while ($null -ne $e) {
        if ($e -is [System.Management.Automation.Remoting.PSRemotingTransportException]) { return $true }
        if ($e -is [System.Management.Automation.Remoting.PSRemotingDataStructureException]) { return $true }
        if ($e -is [System.Management.Automation.RuntimeException] -and $e.ErrorRecord -and $e.ErrorRecord.FullyQualifiedErrorId -match 'PSSessionStateBroken|JobFailure|RemoteHostDisconnected') { return $true }
        if ($e.Message -match '^PAExecUnknown:') { return $true }
        $e = $e.InnerException
    }
    return $false
}
function Invoke-PASLocalTask {
    param([string]$ScriptText,[hashtable]$Parameters,[string]$Contract,[int]$TimeoutSeconds=0)
    $ps=[powershell]::Create()
    try {
        [void]$ps.AddScript($script:PATaskHostText).AddParameter('Code',$ScriptText).AddParameter('Parameters',$Parameters).AddParameter('Contract',$Contract)
        $async=$ps.BeginInvoke()
        $ms=-1; if ($TimeoutSeconds -gt 0) { $ms=$TimeoutSeconds*1000 }
        if (-not $async.AsyncWaitHandle.WaitOne($ms)) {
            try { $ps.Stop() } catch { Write-Verbose 'Local stop failed' }
            throw (New-PASUnknownError "local task exceeded $TimeoutSeconds seconds and was stopped; side effects unknown")
        }
        $out=@($ps.EndInvoke($async))
        if ($out.Count -eq 0) { throw 'Local task host returned no result' }
        return (ConvertTo-PASHashtable $out[-1])
    } finally { $ps.Dispose() }
}
function Invoke-PASWinRMTask {
    param([hashtable]$Target,[hashtable]$Credentials,[string]$ScriptText,[hashtable]$Parameters,[string]$Contract,[int]$TimeoutSeconds=0)
    try { $session=Get-PASConnection $Target $Credentials }
    catch { throw "WinRM connection failed before dispatch: $($_.Exception.Message)" }
    $job=$null
    try {
        $job=Invoke-Command -Session $session -ScriptBlock $script:PATaskHostBlock -ArgumentList $ScriptText,$Parameters,$Contract -AsJob -ErrorAction Stop
        $wait=-1; if ($TimeoutSeconds -gt 0) { $wait=$TimeoutSeconds }
        $finished=Wait-Job -Job $job -Timeout $wait
        if (-not $finished) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            throw (New-PASUnknownError "remote task exceeded $TimeoutSeconds seconds; remote side effects unknown")
        }
        $child=$job.ChildJobs[0]
        $out=@(Receive-Job -Job $job -ErrorAction SilentlyContinue -ErrorVariable remoteErrors)
        if ($child.JobStateInfo.State -eq 'Failed' -or $out.Count -eq 0) {
            $reason=$child.JobStateInfo.Reason
            $text=[string]$reason; if (-not $text -and $remoteErrors) { $text=[string]$remoteErrors[0] }
            throw (New-PASUnknownError "WinRM invocation lost or returned no task result: $text")
        }
        return (ConvertTo-PASHashtable $out[-1])
    } catch {
        if ($_.Exception.Message -match '^PAExecUnknown:') { throw }
        if (Test-PASTransportFailure $_) { throw (New-PASUnknownError "WinRM transport failure: $($_.Exception.Message)") }
        throw
    } finally {
        if ($job) { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
    }
}
function Get-PASSSHBaseArguments {
    param([hashtable]$Target,[switch]$Scp)
    $list=@('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o',('ConnectTimeout='+[string](Get-PASValue $Target 'ConnectTimeoutSeconds' 15)))
    if ($Scp) { $list = @('-B','-q') + $list }
    if ($Target.Contains('KnownHostsFile')) { $list += @('-o',('UserKnownHostsFile='+[string]$Target.KnownHostsFile)) }
    if ($Target.Contains('Port')) { if ($Scp) { $list += @('-P',[string]$Target.Port) } else { $list += @('-p',[string]$Target.Port) } }
    if ($Target.Contains('IdentityFile')) { $list += @('-i',[string]$Target.IdentityFile) }
    return ,$list
}
function Get-PASSSHDestination {
    param([hashtable]$Target)
    $user=[string](Get-PASValue $Target 'User')
    $hostName=[string]$Target.ComputerName
    if ($user -notmatch '^[A-Za-z0-9._-]+$' -or $hostName -notmatch '^[A-Za-z0-9.:-]+$') { throw 'Unsafe SSH user/host' }
    return "$user@$hostName"
}
function ConvertTo-PASSSHNativeArgument {
    param([string]$Value)
    $builder=New-Object Text.StringBuilder
    [void]$builder.Append('"');$slashes=0
    foreach($ch in $Value.ToCharArray()){
        if($ch -eq [char]92){$slashes++;continue}
        if($ch -eq [char]34){[void]$builder.Append([char]92,($slashes*2+1));[void]$builder.Append($ch)}
        else{if($slashes){[void]$builder.Append([char]92,$slashes)};[void]$builder.Append($ch)}
        $slashes=0
    }
    if($slashes){[void]$builder.Append([char]92,($slashes*2))}
    [void]$builder.Append('"')
    return $builder.ToString()
}
function Invoke-PASSSHWindowsFileCapture {
    param([string]$Executable,[object[]]$Arguments,[int]$TimeoutSeconds)
    $tmp=Join-Path ([IO.Path]::GetTempPath()) ('paeasy-ssh-'+[guid]::NewGuid().ToString('N'))
    New-Item $tmp -ItemType Directory -ErrorAction Stop | Out-Null
    Protect-PASDirectory $tmp
    $process=$null
    try {
        # cmd performs native file redirection; no anonymous redirected SSH handles are inherited.
        # Commands are encoded before this function. Reject cmd expansion/quote injection in paths/options.
        foreach($arg in @($Executable,$tmp)+@($Arguments)){
            if([string]$arg -match '["%!\r\n]'){throw 'Unsupported character in Windows SSH invocation'}
        }
        $quoted=@(@($Executable)+@($Arguments) | ForEach-Object {'"'+[string]$_+'"'}) -join ' '
        $stdout=Join-Path $tmp 'stdout.txt';$stderr=Join-Path $tmp 'stderr.txt'
        $batch=Join-Path $tmp 'observe.cmd'
        [IO.File]::WriteAllText($batch,("@echo off`r`n"+$quoted+' >"'+$stdout+'" 2>"'+$stderr+'"'+"`r`nexit /b %errorlevel%`r`n"),[Text.Encoding]::Default)
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$env:ComSpec;$info.Arguments='/d /s /c ""'+$batch+'""'
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $process=New-Object Diagnostics.Process;$process.StartInfo=$info
        if(-not $process.Start()){throw 'Cannot start SSH observer'}
        if(-not $process.WaitForExit($TimeoutSeconds*1000)){
            & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null
            throw (New-PASUnknownError 'SSH observation timed out; target work was not stopped')
        }
        # Native redirection handles can close shortly after cmd exits. Bound the
        # sharing retry; never restart target work because observation raced exit.
        for($readAttempt=0;$readAttempt -lt 20;$readAttempt++){
            try {
                $output=if(Test-Path $stdout){[IO.File]::ReadAllText($stdout)}else{''}
                $errors=if(Test-Path $stderr){[IO.File]::ReadAllText($stderr)}else{''}
                break
            } catch [IO.IOException] {
                if($readAttempt -eq 19){throw}
                Start-Sleep -Milliseconds 100
            }
        }
        return [pscustomobject]@{ExitCode=$process.ExitCode;Output=($output+$errors).TrimEnd()}
    } finally {
        if($process){$process.Dispose()}
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
function Invoke-PASRawSSH {
    param([hashtable]$Target,[string]$RemoteCommand,[byte[]]$InputBytes)
    $exe=Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue
    if(-not $exe){throw 'ssh executable missing'}
    $sshArgs=Get-PASSSHBaseArguments $Target
    $controlBytes=$null
    if((Test-PASWindows) -and -not $InputBytes -and $Target.Runtime -eq 'Bash'){
        # cmd.exe has an 8191-character line limit. Encoded Linux guards/status
        # scripts can exceed it before SSH starts. Keep argv bounded and send
        # the command on the same exact-length stdin protocol used for inputs.
        $controlBytes=[Text.Encoding]::UTF8.GetBytes(([string]$RemoteCommand).Replace("`r`n","`n"))
        $InputBytes=$controlBytes
        $RemoteCommand='head -c '+$controlBytes.Length+' | bash'
    }
    if((Test-PASWindows) -and -not $InputBytes){
        if($Target.Runtime -eq 'Bash'){
            $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($RemoteCommand.Replace("`r`n","`n")))
            $RemoteCommand='echo '+$encoded+' | base64 -d | bash'
        }
        $sshArgs+=@('-n','-T',(Get-PASSSHDestination $Target),$RemoteCommand)
        return Invoke-PASSSHWindowsFileCapture $exe.Source $sshArgs ([int](Get-PASValue $Target 'CommandTimeoutSeconds' 120))
    }
    if((Test-PASWindows) -and $InputBytes -and $Target.Runtime -eq 'Bash'){
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($RemoteCommand))
        $RemoteCommand="bash -c 'eval "+'$(echo '+$encoded+" | base64 -d)'"
    }
    if(-not $InputBytes){$sshArgs+='-n'}
    $sshArgs+=@('-T',(Get-PASSSHDestination $Target),$RemoteCommand)
    # PowerShell 5.1 native capture can leave nested SSH waiting on inherited handles.
    # Explicit streams, closed stdin and concurrent drains keep controller reconnects bounded.
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$exe.Source
    $info.Arguments=(@($sshArgs|ForEach-Object{ConvertTo-PASSSHNativeArgument ([string]$_)}) -join ' ')
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.RedirectStandardInput=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$info
    try {
        if(-not $process.Start()){throw 'Cannot start ssh process'}
        $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if($InputBytes){$process.StandardInput.BaseStream.Write($InputBytes,0,$InputBytes.Length);$process.StandardInput.BaseStream.Flush()}else{$process.StandardInput.Close()}
        $seconds=[int](Get-PASValue $Target 'CommandTimeoutSeconds' 120)
        if(-not $process.WaitForExit($seconds*1000)){
            try{$process.Kill()}catch{}
            throw (New-PASUnknownError 'SSH observation timed out; target work was not stopped')
        }
        $output=$stdout.GetAwaiter().GetResult();$errors=$stderr.GetAwaiter().GetResult()
        return [pscustomobject]@{ExitCode=$process.ExitCode;Output=($output+$errors).TrimEnd()}
    } finally {
        $process.Dispose()
        if($null -ne $controlBytes){[Array]::Clear($controlBytes,0,$controlBytes.Length)}
    }
}
function Test-PASSCPExplicitLegacyMode {
    # Hardened PSMP disables the SFTP subsystem. New OpenSSH clients need -O;
    # older clients already use legacy SCP and do not advertise that switch.
    if(-not(Get-Variable -Name PSScpLegacySupported -Scope Script -ErrorAction SilentlyContinue)){
        $exe=Get-Command scp -CommandType Application -ErrorAction Stop
        if(Test-PASWindows){
            $probe=Invoke-PASSSHWindowsFileCapture $exe.Source @() 15
            $usage=[string]$probe.Output
        }else{
            $usage=(@(& $exe.Source 2>&1) -join ' ')
        }
        $script:PSScpLegacySupported=($usage -match '(?i)usage:.*scp(?:\.exe)? \[-[^\]]*O')
    }
    return [bool]$script:PSScpLegacySupported
}
function Copy-PASRawSSH {
    param([hashtable]$Target,[string]$Source,[string]$Destination,[switch]$Download)
    if($Target.Runtime -eq 'Bash'){
        $remotePath=if($Download){$Source}else{$Destination}
        # Legacy SCP invokes a remote shell: never allow shell metacharacters,
        # traversal or reads outside this module's owned staging namespace.
        if($remotePath -notmatch '^/opt/paeasyinstall/[A-Za-z0-9_./-]+$' -or $remotePath -match '/\.\.?(/|$)'){throw 'Unsafe Linux SCP path'}
    }
    $scpArgs=Get-PASSSHBaseArguments $Target -Scp
    if($Target.Runtime -eq 'Bash' -and (Test-PASSCPExplicitLegacyMode)){ $scpArgs += '-O' }
    $remote=(Get-PASSSHDestination $Target)+':'
    if ($Download) { $scpArgs += @(($remote+$Source),$Destination) }
    else { $scpArgs += @($Source,($remote+$Destination)) }
    if(Test-PASWindows){
        $exe=Get-Command scp -CommandType Application -ErrorAction Stop
        $result=Invoke-PASSSHWindowsFileCapture $exe.Source $scpArgs ([int](Get-PASValue $Target 'TransferTimeoutSeconds' 3600))
        if($result.ExitCode -ne 0){throw "SCP failed ($($result.ExitCode)): $(Limit-PASText $result.Output 1000)"}
    }else{
        $ErrorActionPreference='Continue'
        $output=& scp @scpArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "SCP failed ($LASTEXITCODE): $(Limit-PASText (@($output) -join ' ') 1000)" }
    }
}
function Read-PASResultMarker {
    param([string]$Output,[string]$What)
    $lines=@($Output -split "`r?`n")
    $markers=@($lines | Where-Object { $_.StartsWith('PAEASY_RESULT:') })
    $other=(@($lines | Where-Object { -not $_.StartsWith('PAEASY_RESULT:') }) -join "`n").Trim()
    if ($markers.Count -eq 0) { return [pscustomobject]@{ Found=$false; Value=$null; Other=$other } }
    try { $value=ConvertTo-PASHashtable (ConvertFrom-Json -InputObject ($markers[-1].Substring('PAEASY_RESULT:'.Length))) }
    catch { throw "$What returned a malformed PAEASY_RESULT marker" }
    if ($value -isnot [System.Collections.IDictionary]) { throw "$What result marker must contain a JSON object" }
    return [pscustomobject]@{ Found=$true; Value=$value; Other=$other }
}
function Invoke-PASRawSSHScript {
    param([hashtable]$Target,[string]$ScriptPath,[string]$ScriptText,[hashtable]$Parameters,[string]$Contract,[int]$TimeoutSeconds=0,[string]$AttemptId='')
    if([string](Get-PASValue $Target 'Runtime' 'Bash') -ne 'Bash'){throw 'Windows targets require the qualified native WinRM adapter; SSH PowerShell dispatch is not supported'}
    if($ScriptPath -notmatch '\.(sh|bash)$' -or -not(Test-Path -LiteralPath $ScriptPath -PathType Leaf)){throw 'Bash dispatch requires a reviewed local .sh/.bash task file'}
    if([IO.File]::ReadAllText($ScriptPath).Replace("`r`n","`n") -cne $ScriptText.Replace("`r`n","`n")){throw 'Bash task source changed before dispatch'}
    # Short checks use the same protected, durable input transport as installation.
    # No relative SCP paths or plaintext controller inputs.json are created.
    $attempt=if($AttemptId){$AttemptId}else{[guid]::NewGuid().ToString('N')}
    $null=Get-PASLinuxAttemptRoot $attempt
    $timeout=if($TimeoutSeconds -gt 0){$TimeoutSeconds}else{[int](Get-PASValue $Target 'CommandTimeoutSeconds' 600)}
    [void](Initialize-PASLinuxDetached $Target $ScriptPath $Parameters $attempt $timeout $Contract)
    $remote=Wait-PASDetached $Target @{} $attempt $timeout
    if($remote.state -notin @('Succeeded','Failed')){throw (New-PASUnknownError ('Linux check '+$attempt+' is '+$remote.state+'; reconcile the durable attempt before retry'))}
    $directory=Get-PASLinuxAttemptRoot $attempt
    $outputText=Invoke-PASLinuxControl $Target ('tail -c 262144 -- '+$directory+'/stdout.log.tail')
    $marker=Read-PASResultMarker $outputText 'Bash task'
    $output=Limit-PASText $marker.Other 20000
    $exitCode=[int](Get-PASValue $remote 'exitCode' 1)
    if($remote.state -ne 'Succeeded'){
        return @{Ok=$false;Terminal=$marker.Value;Output=$output;Error=('Bash task '+$attempt+' failed with code '+$exitCode);ExitCode=$exitCode;AttemptId=$attempt}
    }
    if(-not $marker.Found -and $Contract -ne 'ExitCode'){
        return @{Ok=$false;Terminal=$null;Output=$output;Error='Bash task must print PAEASY_RESULT:{json} as its structured result';ExitCode=0;AttemptId=$attempt}
    }
    Finish-PASLinuxDetached $Target $attempt
    return @{Ok=$true;Terminal=$marker.Value;Output=$output;Error=$null;ExitCode=0;AttemptId=$attempt}
}
function Invoke-PASAdapterScript {
    param([hashtable]$Target,[hashtable]$Credentials,[string]$ScriptPath,[hashtable]$Parameters,[string]$Contract='Object',[int]$TimeoutSeconds=0,[string]$ScriptText='',[string]$AttemptId='')
    $protocol=[string]$Target.Protocol
    if (-not $ScriptText) { $ScriptText=(Get-PASRecipePayload $ScriptPath).Text }
    if ($null -eq $Parameters) { $Parameters=@{} }
    if ($protocol -eq 'Local') { return (Invoke-PASLocalTask $ScriptText $Parameters $Contract $TimeoutSeconds) }
    if ($protocol -eq 'SSH') { return (Invoke-PASRawSSHScript $Target $ScriptPath $ScriptText $Parameters $Contract -TimeoutSeconds $TimeoutSeconds -AttemptId $AttemptId) }
    if ($protocol -ne 'WinRM') { throw "Unsupported adapter protocol '$protocol'" }
    if (Test-PASWindows) { return (Invoke-PASWinRMTask $Target $Credentials $ScriptText $Parameters $Contract $TimeoutSeconds) }
    throw 'Windows remoting requires the native Windows PowerShell controller'
}
function Invoke-PASAdapterCommand {
    # Runs a short controller-authored PowerShell snippet on the target. Requires a PowerShell runtime.
    param([hashtable]$Target,[hashtable]$Credentials,[string]$Code,[string]$Contract='ExitCode',[int]$TimeoutSeconds=0)
    if ([string](Get-PASValue $Target 'Runtime' 'WindowsPowerShell') -eq 'Bash') { throw 'PowerShell command requested on a Bash target' }
    $response=Invoke-PASAdapterScript -Target $Target -Credentials $Credentials -ScriptPath 'paeasy-command.ps1' -Parameters @{} -Contract $Contract -TimeoutSeconds $TimeoutSeconds -ScriptText $Code
    if (-not $response.Ok) { throw ([string]$response.Error) }
    return $response
}
function Get-PASLinuxFilePreparation {
    param([string]$RemotePath)
    if($RemotePath -notmatch '^/opt/paeasyinstall/[A-Za-z0-9_-]+(?:/[A-Za-z0-9_.-]+)*$' -or $RemotePath -match '/\.\.?(/|$)'){throw 'Unsafe Linux transfer destination'}
    # Verify every ancestor before creating directories or allowing SCP to open a file.
    # Root is the trust boundary; no group/other writer may redirect the destination.
    $body=@'
set -eu
umask 077
destination='__DESTINATION__'
trusted() {
    [ ! -L "$1" ] && [ "$(stat -c %u -- "$1")" = 0 ] || return 1
    mode=$(stat -c %a -- "$1")
    [ "$((8#$mode & 022))" = 0 ]
}
trusted / && [ -d / ] || exit 71
parent=${destination%/*}
current=
IFS=/ read -r -a segments <<< "$parent"
for segment in "${segments[@]}"; do
    [ -n "$segment" ] || continue
    current="$current/$segment"
    if [ -e "$current" ] || [ -L "$current" ]; then
        [ -d "$current" ] && trusted "$current" || exit 72
    else
        mkdir -m 700 -- "$current"
        [ -d "$current" ] && trusted "$current" || exit 73
    fi
done
if [ -e "$destination" ] || [ -L "$destination" ]; then
    [ -f "$destination" ] && trusted "$destination" || exit 74
    [ "$(stat -c %h -- "$destination")" = 1 ] || exit 75
fi
'@
    return $body.Replace('__DESTINATION__',$RemotePath)
}
function Copy-PASAdapterFile {
    param([hashtable]$Target,[hashtable]$Credentials,[string]$LocalPath,[string]$RemotePath,[switch]$Download)
    if ($Target.Protocol -eq 'Local') {
        if ($Download) { Copy-Item -LiteralPath $RemotePath -Destination $LocalPath -Force }
        else { Copy-Item -LiteralPath $LocalPath -Destination $RemotePath -Force }
        return
    }
    if ($Target.Protocol -eq 'SSH') {
        if ($Download) { Copy-PASRawSSH $Target $RemotePath $LocalPath -Download }
        else {
            if($Target.Runtime -eq 'Bash'){
                if([string]$Target.User -ne 'root'){throw 'Linux media staging requires the qualified root SSH identity'}
                [void](Invoke-PASLinuxControl $Target (Get-PASLinuxFilePreparation $RemotePath))
            }
            Copy-PASRawSSH $Target $LocalPath $RemotePath
        }
        return
    }
    if (Test-PASWindows) {
        $session=Get-PASConnection $Target $Credentials
        try {
            if ($Download) { Copy-Item -FromSession $session -LiteralPath $RemotePath -Destination $LocalPath -Force -ErrorAction Stop }
            else {
                $reference=[string](Get-PASValue $Target 'CredentialRef' '')
                $user=if($reference -and $Credentials.ContainsKey($reference)){[string]$Credentials[$reference].UserName}else{''}
                $prepared=Invoke-Command -Session $session -ScriptBlock (Get-PASWindowsFilePreparation) -ArgumentList $RemotePath,$user -ErrorAction Stop
                $length=(Get-Item -LiteralPath $LocalPath -ErrorAction Stop).Length
                if($prepared.ApprovedRoot.TrimEnd('\') -eq [IO.Path]::GetPathRoot($prepared.ApprovedRoot).TrimEnd('\')){
                    # The legacy vendor recovery-public-key path is at the volume root.
                    # Keep this bounded and encrypted in PSRP, with no secret-bearing code.
                    if($length -gt 1MB){throw 'Volume-root uploads are limited to small explicit files'}
                    $bytes=[IO.File]::ReadAllBytes($LocalPath)
                    try{$payload=ConvertTo-SecureString ([Convert]::ToBase64String($bytes)) -AsPlainText -Force}finally{[Array]::Clear($bytes,0,$bytes.Length)}
                    try{
                        $received=Invoke-Command -Session $session -ArgumentList $RemotePath,$payload,$length -ErrorAction Stop -ScriptBlock {
                            param($path,[Security.SecureString]$payload,[long]$length)
                            $ErrorActionPreference='Stop';$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($payload);$data=$null
                            try{
                                $data=[Convert]::FromBase64String([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr))
                                if($data.Length -ne $length -or $length -gt 1MB){throw 'Small upload length mismatch'}
                                $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
                                try{$stream.SetLength(0);$stream.Write($data,0,$data.Length)}finally{$stream.Dispose()}
                                [pscustomobject]@{Bytes=$length;Sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
                            }finally{if($data){[Array]::Clear($data,0,$data.Length)};[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
                        }
                    }finally{$payload.Dispose()}
                }else{
                    $receiver=Join-Path $script:PASRoot 'Recipes/WindowsComponent/OwnedFileReceiver.ps1'
                    $source=[IO.File]::OpenRead($LocalPath)
                    try{
                        $offset=[long]0
                        do{
                            $batchLength=[Math]::Min([long](16MB),($length-$offset))
                            $batchEnd=$offset+$batchLength
                            $final=($batchEnd -eq $length)
                            $expectedPartial=if($offset -eq 0){-1}else{$offset}
                            $received=& {
                                $buffer=New-Object byte[] 65536
                                while($source.Position -lt $batchEnd){
                                    $take=[int][Math]::Min([long]$buffer.Length,($batchEnd-$source.Position))
                                    $count=$source.Read($buffer,0,$take)
                                    if($count -lt 1){throw 'Source file ended during PSRP upload'}
                                    $chunk=New-Object byte[] $count;[Array]::Copy($buffer,0,$chunk,0,$count)
                                    Write-Output -NoEnumerate $chunk
                                }
                            } | Invoke-Command -Session $session -FilePath $receiver -ArgumentList $RemotePath,([string]$prepared.ApprovedRoot),$length,21474836480,65536,$user,$offset,$expectedPartial,$final -ErrorAction Stop
                            if($received.NextOffset -ne $batchEnd){throw 'PSRP batch did not confirm its expected offset'}
                            $offset=$batchEnd
                        }while($offset -lt $length)
                    }finally{$source.Dispose()}
                }
                $confirmed=if($received.PSObject.Properties['NextOffset']){[long]$received.NextOffset}else{[long]$received.Bytes}
                if($confirmed -ne $length){throw 'PSRP upload did not confirm its expected length'}
                if($received.Sha256 -ne (Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash){throw 'PSRP upload digest differs from the controller source'}
            }
        } catch {
            Clear-PASConnections
            throw
        }
        return
    }
    throw 'Windows file transfer requires the native Windows PowerShell controller'
}
function Get-PASRemoteFileHash {
    param([hashtable]$Target,[hashtable]$Credentials,[string]$Path)
    if ($Target.Protocol -eq 'Local') {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    }
    if ([string](Get-PASValue $Target 'Runtime' 'WindowsPowerShell') -eq 'Bash') {
        $quoted="'" + $Path.Replace("'","'\''") + "'"
        $r=Invoke-PASRawSSH $Target "if [ -f $quoted ]; then sha256sum -- $quoted | cut -d' ' -f1; fi"
        if ($r.ExitCode -eq 255) { throw (New-PASUnknownError 'SSH lost while hashing remote file') }
        if ($r.ExitCode -ne 0) { throw "Remote hash failed: $($r.Output)" }
        return ([string]$r.Output).Trim().ToUpperInvariant()
    }
    $code='$p='+(ConvertTo-PASSingleQuoted $Path)+'; $h=''''; if(Test-Path -LiteralPath $p -PathType Leaf){$h=(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash}; [pscustomobject]@{Message=''hash'';Hash=$h}'
    $r=Invoke-PASAdapterCommand $Target $Credentials $code 'Object'
    return ([string](Get-PASValue $r.Terminal 'Hash' '')).ToUpperInvariant()
}
function Copy-PASRelayFiles {
    # Key bytes stay in SecureString PSRP payloads, never code, task Data or JSON.
    param([hashtable]$SourceTarget,[hashtable]$DestinationTarget,[hashtable]$Credentials,[string]$SourceDir,[string]$DestinationDir,[string[]]$Files,[int]$MaxBytes=1048576)
    if(-not(Test-PASWindows) -or $SourceTarget.Protocol -ne 'WinRM' -or $DestinationTarget.Protocol -ne 'WinRM'){throw 'Qualified binary relay requires Windows WinRM endpoints'}
    if(@($Files).Count -eq 0){throw 'Relay requires an explicit filename allowlist'}
    $sourceSession=Get-PASConnection $SourceTarget $Credentials
    $destinationSession=Get-PASConnection $DestinationTarget $Credentials
    $reference=[string](Get-PASValue $DestinationTarget 'CredentialRef' '')
    $user=if($reference -and $Credentials.ContainsKey($reference)){[string]$Credentials[$reference].UserName}else{''}
    $sourceReference=[string](Get-PASValue $SourceTarget 'CredentialRef' '')
    $sourceUser=if($sourceReference -and $Credentials.ContainsKey($sourceReference)){[string]$Credentials[$sourceReference].UserName}else{''}
    $changed=$false
    foreach($name in $Files){
        if($name -notmatch '^[A-Za-z0-9_.-]+$' -or $name -in @('.','..')){throw 'Relay filename must be a simple basename'}
        $source=Join-Path $SourceDir $name;$destination=Join-Path $DestinationDir $name
        $record=Invoke-Command -Session $sourceSession -ArgumentList $source,$MaxBytes,$sourceUser -ErrorAction Stop -ScriptBlock {
            param($path,[int]$limit,[string]$managementUser)
            $ErrorActionPreference='Stop'
            if($path -notmatch '^[A-Za-z]:\\' -or $path.Substring(2).Contains(':') -or $limit -lt 1 -or $limit -gt 1MB){throw 'Unsafe relay source path or size limit'}
            $trusted=@('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
            if($managementUser){
                if($managementUser.StartsWith('.\')){$managementUser=$env:COMPUTERNAME+'\'+$managementUser.Substring(2)}
                elseif(-not $managementUser.Contains('\') -and -not $managementUser.Contains('@')){$managementUser=$env:COMPUTERNAME+'\'+$managementUser}
                $trusted+=([Security.Principal.NTAccount]::new($managementUser)).Translate([Security.Principal.SecurityIdentifier]).Value
            }
            try{$trusted+=([Security.Principal.NTAccount]::new('NT SERVICE\TrustedInstaller')).Translate([Security.Principal.SecurityIdentifier]).Value}catch{}
            $cursor=[IO.Path]::GetFullPath($path)
            while($cursor){
                $entry=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
                if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Relay source has a reparse ancestor'}
                if((Get-Acl -LiteralPath $cursor).GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'Relay source has an untrusted owner'}
                $next=Split-Path $cursor -Parent;if($next -eq $cursor){break};$cursor=$next
            }
            $item=Get-Item -LiteralPath $path -ErrorAction Stop
            if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt $limit){throw 'Invalid or oversized relay source'}
            $bytes=[IO.File]::ReadAllBytes($path)
            try{
                $sha=[Security.Cryptography.SHA256]::Create()
                try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
                [pscustomobject]@{Payload=(ConvertTo-SecureString ([Convert]::ToBase64String($bytes)) -AsPlainText -Force);Hash=$hash}
            }finally{[Array]::Clear($bytes,0,$bytes.Length)}
        }
        if($record.Payload -isnot [Security.SecureString]){throw 'Relay did not return an encrypted PSRP payload'}
        try{
            [void](Invoke-Command -Session $destinationSession -ScriptBlock (Get-PASWindowsFilePreparation) -ArgumentList $destination,$user,$false,$false -ErrorAction Stop)
            $result=Invoke-Command -Session $destinationSession -ArgumentList $destination,$record.Payload,([string]$record.Hash),$MaxBytes -ErrorAction Stop -ScriptBlock {
                param($path,[Security.SecureString]$payload,[string]$expected,[int]$limit)
                $ErrorActionPreference='Stop'
                if(Test-Path -LiteralPath $path){
                    if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expected){throw 'Refusing to overwrite a differing relay destination'}
                    return [pscustomobject]@{Changed=$false;Hash=$expected}
                }
                $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($payload);$bytes=$null;$tmp=$null
                try{
                    $bytes=[Convert]::FromBase64String([Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr))
                    if($bytes.Length -gt $limit){throw 'Relay payload exceeds the size limit'}
                    $tmp=Join-Path ([IO.Path]::GetDirectoryName($path)) ('paeasy-relay-'+[guid]::NewGuid().ToString('N')+'.tmp')
                    $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
                    foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','Allow'))}
                    $scope=[PASeasyInstall.Native.RestorePrivilegeScopeV1]::Enable()
                    try{$stream=[IO.FileStream]::new($tmp,[IO.FileMode]::CreateNew,[Security.AccessControl.FileSystemRights]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::None,$acl)}finally{$scope.Dispose()}
                    try{$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
                    if((Get-FileHash $tmp -Algorithm SHA256).Hash -ne $expected){throw 'Relay target digest mismatch'}
                    [IO.File]::Move($tmp,$path);$tmp=$null
                    [pscustomobject]@{Changed=$true;Hash=$expected}
                }finally{
                    if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}
                    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
                    if($tmp -and (Test-Path -LiteralPath $tmp)){Remove-Item -LiteralPath $tmp -Force}
                }
            }
            if($result.Hash -ne [string]$record.Hash){throw 'Relay target verification failed'}
            if($result.Changed){$changed=$true}
        }finally{$record.Payload.Dispose();$record=$null}
    }
    return $changed
}
