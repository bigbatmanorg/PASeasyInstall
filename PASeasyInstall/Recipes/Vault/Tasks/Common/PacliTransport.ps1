# Supplied PACLI v15 transport. Passwords enter one private, PID-bound named pipe,
# never process arguments or a batch file. A delivered batch is NOT an auth proof.
function ConvertTo-PAPacliLiteral {
    param([AllowEmptyString()][string]$Value)
    # Actual v15 parser experiments rejected quote escaping and corrupted Unicode.
    if ($Value.Length -gt 4096 -or
        $Value -match '[^\x20-\x21\x23-\x7e]') { throw 'PACLI v15 pipe values require printable ASCII without double quotes; controls and Unicode are unsupported' }
    return ('"' + $Value + '"')
}
function New-PAPacliSecretStatement {
    param(
        [ValidateSet('LOGON', 'UPDATEUSER')][string]$Operation,
        [ValidateRange(1, 2147483647)][int]$SessionId,
        [hashtable]$Values
    )
    $keys = if ($Operation -eq 'LOGON') { @('PASSWORD') }else { @('DESTUSER', 'DISABLED', 'PASSWORD') }
    if ($Values.Count -ne $keys.Count -or
        @($Values.Keys | Where-Object { $_ -notin $keys }).Count) { throw 'Unexpected PACLI secret command fields' }
    if (-not [string]$Values.PASSWORD) { throw 'PACLI password cannot be empty' }
    $parts = @($Operation)
    foreach ($key in $keys) {
        if ($Values[$key] -isnot [string]) { throw 'PACLI command fields must be strings resolved inside the protected task' }
        if ($key -eq 'DISABLED') {
            if ([string]$Values[$key] -notin @('YES', 'NO')) { throw 'Invalid PACLI disabled flag' }
            $parts += ($key + '=' + [string]$Values[$key])
        } else { $parts += ($key + '=' + (ConvertTo-PAPacliLiteral ([string]$Values[$key]))) }
    }
    # EXECUTEFILE does not reliably propagate its SESSIONID to inner statements.
    $parts += ('SESSIONID=' + $SessionId)
    return (($parts -join ' ') + ';' + "`r`n")
}
function Initialize-PAPacliPipeInterop {
    if ('PAEasyPacli.NativeIO' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace PAEasyPacli {
 public static class NativeIO {
  [DllImport("kernel32.dll",SetLastError=true)]
  public static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe,out uint processId);
  public static async Task<string> Drain(TextReader reader,int maximum) {
   var text=new StringBuilder();var buffer=new char[4096];int count;
   while((count=await reader.ReadAsync(buffer,0,buffer.Length).ConfigureAwait(false))>0) {
    if(text.Length+count>maximum)throw new InvalidDataException("PACLI output exceeded its bound");
    text.Append(buffer,0,count);
   }
   return text.ToString();
  }
 }
}
'@
}
function New-PAPacliInputPipe {
    param([ValidatePattern('^PAEasy-Pacli-[a-f0-9]{32}$')][string]$Name)
    if ($env:OS -ne 'Windows_NT') { throw 'PACLI named pipes require Windows' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [IO.Pipes.PipeSecurity]::new()
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($sid.Value, 'S-1-5-18') | Select-Object -Unique) {
        $security.AddAccessRule([IO.Pipes.PipeAccessRule]::new([Security.Principal.SecurityIdentifier]::new($identity), [IO.Pipes.PipeAccessRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
    }
    return [IO.Pipes.NamedPipeServerStream]::new($Name, [IO.Pipes.PipeDirection]::Out, 1, [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous, 0, 4096, $security)
}
function Assert-PAPacliBinary {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.StartsWith('\\')) { throw 'PACLI requires a local Windows volume path' }
    # Reviewed PACLI builds are accepted by hash; other releases only when Authenticode-signed by CyberArk Software Ltd.
    $reviewed = @('37697F5A91FDAC47997B2D39CA997F161D3FC86D326937F7298C726F53ADBBD4')
    if ((Get-FileHash -LiteralPath $full -Algorithm SHA256 -ErrorAction Stop).Hash -notin $reviewed) {
        $sig = Get-AuthenticodeSignature -LiteralPath $full -ErrorAction Stop
        if ($sig.Status -ne 'Valid' -or
            -not $sig.SignerCertificate -or
            $sig.SignerCertificate.Subject -notmatch '(^|,\s*)O=CyberArk Software Ltd\.(,|$)') { throw 'PACLI executable is neither a reviewed build nor validly signed by CyberArk Software Ltd.' }
    }
    $trusted = @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $caller = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($caller -notmatch '^S-1-5-94-') { $trusted += @($caller) }
    $cursor = $full
    $parent = Split-Path $full -Parent
    while ($cursor) {
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'PACLI path has a reparse ancestor' }
        $acl = Get-Acl -LiteralPath $cursor -ErrorAction Stop
        if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted) { throw 'PACLI path has an untrusted owner' }
        [long]$rights = 0x10000000L -bor 0x40000000L -bor 0x40000L -bor 0x80000L -bor 0x10000L -bor 0x40L -bor 0x100L -bor 0x10L
        # The executable directory must also prevent planting a loader dependency.
        if (-not $item.PSIsContainer -or $cursor -eq $parent) { $rights = $rights -bor 2L -bor 4L }
        foreach ($ace in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            if ($ace.AccessControlType -eq 'Allow' -and
                -not($ace.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and
                $ace.IdentityReference.Value -notin $trusted -and
                ([long]$ace.FileSystemRights -band $rights)) { throw ('PACLI path permits untrusted modification at ' + $cursor + ' by ' + $ace.IdentityReference.Value) }
        }
        $next = Split-Path $cursor -Parent
        if ($next -eq $cursor) { break }
        $cursor = $next
    }
    return $full
}
function Invoke-PAPacliProcess {
    param([string]$Pacli,
        [ValidateSet('INIT', 'DEFINE', 'DEFAULT', 'OPENSAFE', 'CLOSESAFE', 'LOGOFF', 'TERM', 'USERDETAILS', 'ADDSAFE', 'EXECUTEFILE', 'RETRIEVEFILE', 'STOREFILE')][string]$Operation,
        [ValidateRange(1, 2147483647)][int]$SessionId,
        [string[]]$Arguments = @(),
        [byte[]]$PipeBytes,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 30)
    if ($env:OS -ne 'Windows_NT') { throw 'PACLI transport requires Windows' }
    Initialize-PAPacliPipeInterop
    $exe = Assert-PAPacliBinary $Pacli
    foreach ($argument in $Arguments) {
        if ($argument -notmatch '^(?:VAULT|ADDRESS|USER|DESTUSER|SAFE|TIMEOUT|FILE|FOLDER|LOCALFOLDER|LOCALFILE)=[A-Za-z0-9_.(),=\\:-]+$' -and
            $argument -cnotin @('LOCATION=\', 'SIZE=5', 'DESCRIPTION=PAExecReplicationTest') -and
            $argument -notmatch '^OUTPUT\((?:ENCLOSE,)?(?:NAME,DISABLED|SAFEID)\)$') { throw 'Unsafe or secret-bearing PACLI process argument' }
    }
    if ($Operation -eq 'ADDSAFE') {
        if ($Arguments.Count -ne 4 -or
            @($Arguments | Where-Object { $_ -cmatch '^SAFE=PAExecRepl[a-f0-9]{12}$' }).Count -ne 1 -or
            @($Arguments | Where-Object { $_ -ceq 'LOCATION=\' }).Count -ne 1 -or
            @($Arguments | Where-Object { $_ -ceq 'SIZE=5' }).Count -ne 1 -or
            @($Arguments | Where-Object { $_ -ceq 'DESCRIPTION=PAExecReplicationTest' }).Count -ne 1) { throw 'ADDSAFE is restricted to the declared replication fixture' }
    } elseif (@($Arguments | Where-Object { $_ -cmatch '^(LOCATION|SIZE|DESCRIPTION)=' }).Count) { throw 'Replication fixture fields require ADDSAFE' }
    if (($Operation -eq 'EXECUTEFILE') -ne ($null -ne $PipeBytes -and
            $PipeBytes.Length -gt 0)) { throw 'EXECUTEFILE requires exactly one private pipe payload' }
    if ($Operation -eq 'EXECUTEFILE' -and $Arguments.Count) { throw 'Caller cannot choose a PACLI pipe filename' }
    $pipe = $null
    $process = $null
    $started = $false
    $bytesWritten = $false
    $connected = $null
    try {
        if ($Operation -eq 'EXECUTEFILE') {
            if ($PipeBytes.Length -gt 16384) { throw 'PACLI pipe payload exceeds its bound' }
            $name = 'PAEasy-Pacli-' + [guid]::NewGuid().ToString('N')
            $pipe = New-PAPacliInputPipe $name
            $connected = $pipe.BeginWaitForConnection($null, $null)
            $Arguments = @('FILE=\\.\pipe\' + $name)
        }
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $exe
        $info.WorkingDirectory = Split-Path $exe -Parent
        $info.Arguments = (@($Operation, ('SESSIONID=' + $SessionId)) + $Arguments) -join ' '
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.EnvironmentVariables['PATH'] = $info.WorkingDirectory + ';' + [Environment]::GetFolderPath('System') + ';' + $env:WINDIR
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        if (-not $process.Start()) { throw 'PACLI client did not start' }
        $started = $true
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $stdout = [PAEasyPacli.NativeIO]::Drain($process.StandardOutput, 131072)
        $stderr = [PAEasyPacli.NativeIO]::Drain($process.StandardError, 131072)
        if ($pipe) {
            while (-not $connected.AsyncWaitHandle.WaitOne(50)) {
                if ($process.HasExited -or
                    [DateTime]::UtcNow -ge $deadline) { throw 'PAExecUnknown: PACLI client did not connect to its private pipe' }
            }
            $pipe.EndWaitForConnection($connected)
            [uint32]$peer = 0
            if (-not [PAEasyPacli.NativeIO]::GetNamedPipeClientProcessId($pipe.SafePipeHandle, [ref]$peer) -or
                $peer -ne $process.Id -or
                $process.HasExited) { throw 'PAExecUnknown: PACLI pipe client identity mismatch' }
            $write = $pipe.BeginWrite($PipeBytes, 0, $PipeBytes.Length, $null, $null)
            $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            try {
                if (-not $write.AsyncWaitHandle.WaitOne($remaining)) { throw 'PAExecUnknown: PACLI pipe delivery timed out' }
                $pipe.EndWrite($write)
                $bytesWritten = $true
            } finally { $write.AsyncWaitHandle.Dispose() }
            $pipe.Dispose()
            $pipe = $null
        }
        $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $process.WaitForExit($remaining)) { throw 'PAExecUnknown: PACLI command timed out; reconcile the isolated session before retry' }
        try {
            $remaining = [Math]::Max(1, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), $remaining)) { throw 'Output streams did not close' }
            $out = $stdout.GetAwaiter().GetResult()
            $err = $stderr.GetAwaiter().GetResult()
        } catch { throw 'PAExecUnknown: PACLI output capture was incomplete or exceeded its bound' }
        if ($Operation -eq 'EXECUTEFILE') {
            # Do not expose native output: parser errors may echo secret input.
            if (-not $bytesWritten -or
                $process.ExitCode -ne 0 -or
                $err.Trim() -or
                $out.Trim()) { throw 'PACLI secret command did not complete cleanly; native text suppressed' }
            return [pscustomobject]@{
                ExitCode = 0
                Delivered = $true
                ClientPID = $process.Id
                NativeAuthenticationVerified = $false
            }
        }
        return [pscustomobject]@{ExitCode = $process.ExitCode; Out = $out; Err = $err; ClientPID = $process.Id }
    } finally {
        if ($pipe) { $pipe.Dispose() }
        if ($connected) { $connected.AsyncWaitHandle.Dispose() }
        if ($process) {
            try {
                if ($started -and
                    -not $process.HasExited) {
                    $process.Kill()
                    [void]$process.WaitForExit(5000)
                }
            } finally { $process.Dispose() }
        }
        if ($PipeBytes) { [Array]::Clear($PipeBytes, 0, $PipeBytes.Length) }
    }
}
function Invoke-PAPacliSecretCommand {
    param(
        [string]$Pacli,
        [ValidateSet('LOGON', 'UPDATEUSER')][string]$Operation,
        [int]$SessionId,
        [hashtable]$Values,
        [int]$TimeoutSeconds = 30
    )
    $statement = New-PAPacliSecretStatement $Operation $SessionId $Values
    $bytes = [Text.Encoding]::ASCII.GetBytes($statement)
    try { Invoke-PAPacliProcess -Pacli $Pacli -Operation EXECUTEFILE -SessionId $SessionId -PipeBytes $bytes -TimeoutSeconds $TimeoutSeconds }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
        $statement = $null
    }
}
function Open-PAPacliVaultSession {
    # -Address: the Vault as seen from this server. Default: this server is the Vault.
    param([string]$Pacli, [string]$Password, [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$')][string]$Address = '127.0.0.1')
    $id = Get-Random -Minimum 2000000 -Maximum 2000000000
    # Refuse unsupported text before INIT, and therefore before any login attempt.
    $null = New-PAPacliSecretStatement LOGON $id @{PASSWORD = $Password }
    $context = @{
        Path = $Pacli
        Id = $id
        Initialized = $false
        Authenticated = $false
        AuthAttempted = $false
        Closed = $false
        Codes = [Collections.Generic.List[string]]::new()
    }
    try {
        foreach ($entry in @(@{
                    Op = 'INIT'
                    Args = @()
                }, @{
                    Op = 'DEFINE'
                    Args = @('VAULT=v', ('ADDRESS=' + $Address), 'TIMEOUT=10')
                }, @{
                    Op = 'DEFAULT'
                    Args = @('VAULT=v', 'USER=Administrator')
                })) {
            $result = Invoke-PAPacliProcess -Pacli $Pacli -Operation $entry.Op -SessionId $id -Arguments $entry.Args
            $context.Codes.Add(($entry.Op.ToLowerInvariant() + '=' + $result.ExitCode))
            if ($entry.Op -eq 'INIT' -and $result.ExitCode -eq 0) { $context.Initialized = $true }
            if (-not(Test-PAPacliCleanAcknowledgement $result)) { throw ('PACLI ' + $entry.Op + ' failed') }
        }
        $context.AuthAttempted = $true
        $delivery = Invoke-PAPacliSecretCommand -Pacli $Pacli -Operation LOGON -SessionId $id -Values @{PASSWORD = $Password }
        if ($delivery.Delivered -isnot [bool] -or
            -not $delivery.Delivered -or
            $delivery.ExitCode -ne 0) { throw 'PACLI password pipe delivery is unconfirmed' }
        # Native EXECUTEFILE can return zero for an internal failure. This separate
        # authenticated operation must return the exact expected identity/flag.
        $query = Invoke-PAPacliProcess -Pacli $Pacli -Operation USERDETAILS -SessionId $id -Arguments @('DESTUSER=Administrator', 'OUTPUT(ENCLOSE,NAME,DISABLED)')
        if (-not(Test-PAPacliNativeResult $query) -or
            $query.ExitCode -ne 0 -or
            ([string]$query.Err).Trim() -or
            ([string]$query.Out).Trim() -cne '"Administrator","NO"') { throw 'PACLI independent authenticated identity verification failed' }
        $context.Authenticated = $true
        $context.Codes.Add('logon-pipe=0')
        $context.Codes.Add('identity=verified')
        return $context
    } catch {
        $failure = $_
        if ($context.Initialized) { Close-PAPacliVaultSession $context }
        if ($context.Closed) {
            $known = [InvalidOperationException]::new('PACLI authenticated session could not be established; isolated session closed')
            $known.Data['PAPacliSessionClosed'] = $true
            $known.Data['PAPacliAuthAttempted'] = [bool]$context.AuthAttempted
            throw $known
        }
        throw $failure
    } finally { $Password = $null }
}
function Test-PAPacliNativeResult {
    param($Result)
    return (($Result.ExitCode -is [int] -or $Result.ExitCode -is [long]) -and $Result.Out -is [string] -and $Result.Err -is [string])
}
function Test-PAPacliCleanAcknowledgement {
    param($Result)
    return ((Test-PAPacliNativeResult $Result) -and
        $Result.ExitCode -eq 0 -and
        -not ([string]$Result.Out).Trim() -and
        -not ([string]$Result.Err).Trim())
}
function Test-PAPacliLoggedOutResult {
    param($Result)
    # Qualified native English v15 diagnostic; never accept a generic connection error.
    return ((Test-PAPacliNativeResult $Result) -and
        $Result.ExitCode -eq -1 -and
        -not ([string]$Result.Out).Trim() -and
        ([string]$Result.Err).Trim() -ceq 'User is not logged on. Please log on.')
}
function Close-PAPacliVaultSession {
    param([hashtable]$Session)
    if ($Session.Closed) { return }
    if (-not $Session.Initialized) { throw 'PAExecUnknown: PACLI session initialization was not acknowledged' }
    $closed = $false
    $terminated = $false
    try {
        $off = Invoke-PAPacliProcess -Pacli $Session.Path -Operation LOGOFF -SessionId $Session.Id
        $Session.Codes.Add(('logoff=' + $off.ExitCode))
        if (-not(Test-PAPacliCleanAcknowledgement $off) -and
            -not(Test-PAPacliLoggedOutResult $off)) { throw 'PACLI logoff was not acknowledged' }
        $check = Invoke-PAPacliProcess -Pacli $Session.Path -Operation USERDETAILS -SessionId $Session.Id -Arguments @('DESTUSER=Administrator', 'OUTPUT(ENCLOSE,NAME,DISABLED)')
        if (-not(Test-PAPacliLoggedOutResult $check)) { throw 'PACLI post-logoff unauthenticated state is unconfirmed' }
        $closed = $true
    } finally {
        try {
            $end = Invoke-PAPacliProcess -Pacli $Session.Path -Operation TERM -SessionId $Session.Id
            $Session.Codes.Add(('term=' + $end.ExitCode))
            $terminated = Test-PAPacliCleanAcknowledgement $end
        } catch { $terminated = $false }
        $Session.Closed = ($closed -and $terminated)
        if (-not $Session.Closed) { throw ('PAExecUnknown: PACLI isolated session ' + $Session.Id + ' cleanup is unconfirmed; reconcile before another login') }
    }
}
function Get-PAPacliTestSafeName {
    param([string]$RunId)
    if ($RunId -notmatch '^[a-fA-F0-9]{32}$') { throw 'Replication test Safe requires a complete hexadecimal deployment run ID' }
    return ('PAExecRepl' + $RunId.Substring(0, 12).ToLowerInvariant())
}
function Assert-PAPacliAuthenticatedContext {
    param([hashtable]$Session)
    if ($Session.Authenticated -isnot [bool] -or
        -not $Session.Authenticated -or
        $Session.Closed -isnot [bool] -or
        $Session.Closed) { throw 'PACLI Safe operation requires a verified open authenticated context' }
}
function Open-PAPacliSafe {
    param([hashtable]$Session, [ValidatePattern('^[A-Za-z][A-Za-z0-9_.-]{0,27}$')][string]$Name, [switch]$AllowMissing)
    Assert-PAPacliAuthenticatedContext $Session
    $result = Invoke-PAPacliProcess -Pacli $Session.Path -Operation OPENSAFE -SessionId $Session.Id -Arguments @(('SAFE=' + $Name), 'OUTPUT(ENCLOSE,SAFEID)')
    if ((Test-PAPacliNativeResult $result) -and
        $result.ExitCode -eq 0 -and
        -not ([string]$result.Err).Trim() -and
        ([string]$result.Out).Trim() -cmatch '^"([1-9][0-9]{0,9})"$') {
        $Session.Codes.Add('safe-open=verified')
        return [pscustomobject]@{Exists = $true; SafeId = $Matches[1] }
    }
    $missing = "ITATS020E Safe Name " + $Name + " hasn't been defined."
    if ($AllowMissing -and
        (Test-PAPacliNativeResult $result) -and
        $result.ExitCode -eq -1 -and
        -not ([string]$result.Out).Trim() -and
        ([string]$result.Err).Trim() -ceq $missing) {
        $Session.Codes.Add('safe-missing=verified')
        return [pscustomobject]@{Exists = $false; SafeId = '' }
    }
    throw 'PACLI Safe access is unconfirmed; native diagnostic suppressed'
}
function Close-PAPacliSafe {
    param([hashtable]$Session, [ValidatePattern('^[A-Za-z][A-Za-z0-9_.-]{0,27}$')][string]$Name)
    Assert-PAPacliAuthenticatedContext $Session
    $result = Invoke-PAPacliProcess -Pacli $Session.Path -Operation CLOSESAFE -SessionId $Session.Id -Arguments @(('SAFE=' + $Name))
    if (-not(Test-PAPacliCleanAcknowledgement $result)) { throw 'PACLI Safe close acknowledgement is unconfirmed' }
    $Session.Codes.Add('safe-close=0')
}
function Add-PAPacliTestSafe {
    param([hashtable]$Session, [ValidatePattern('^PAExecRepl[a-f0-9]{12}$')][string]$Name)
    Assert-PAPacliAuthenticatedContext $Session
    $result = Invoke-PAPacliProcess -Pacli $Session.Path -Operation ADDSAFE -SessionId $Session.Id -Arguments @(('SAFE=' + $Name), 'LOCATION=\', 'SIZE=5', 'DESCRIPTION=PAExecReplicationTest')
    if (-not(Test-PAPacliCleanAcknowledgement $result)) { throw 'PACLI replication Safe creation was not acknowledged' }
    $Session.Codes.Add('addsafe=0')
}
