# Pre-steps the run controller performs on the controller machine right before a component runs:
#   - key-based SSH for a Linux server (password used once, never stored),
#   - the PSMP package that matches the server's distribution,
#   - the HTTPS certificate of the PVWA a CPM pins (lab: self-signed PVWA certificate).
# Their progress goes to the run's event journal (Write-PASRunEvent).

function Invoke-PASNativeQuiet {
    <# Runs an OpenSSH tool and returns @{ExitCode;Output}. On Windows the tool runs under cmd.exe with
       native file redirection in a hidden console (Win32 OpenSSH can hang when PowerShell captures its
       streams), bounded by a timeout, the same way the engine observes SSH. #>
    param([string]$Exe, [string[]]$Arguments, [int]$TimeoutSeconds = 90)
    if ($env:OS -ne 'Windows_NT') {
        $saved = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = @() | & $Exe @Arguments 2>&1
            $code = $LASTEXITCODE
        } finally { $ErrorActionPreference = $saved }
        return @{ExitCode = $code; Output = (@($out | ForEach-Object { [string]$_ }) -join "`n") }
    }
    foreach ($arg in @($Exe) + @($Arguments)) { if ([string]$arg -match '["%!\r\n]') { throw 'Unsupported character in an SSH tool argument' } }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('paseasy-tool-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    $process = $null
    try {
        $stdout = Join-Path $tmp 'out.txt'
        $stderr = Join-Path $tmp 'err.txt'
        $batch = Join-Path $tmp 'run.cmd'
        $quoted = @(@($Exe) + @($Arguments) | ForEach-Object { '"' + [string]$_ + '"' }) -join ' '
        [IO.File]::WriteAllText($batch, ("@echo off`r`n" + $quoted + ' <nul >"' + $stdout + '" 2>"' + $stderr + '"' + "`r`nexit /b %errorlevel%`r`n"), [Text.Encoding]::Default)
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $env:ComSpec
        $info.Arguments = '/d /s /c ""' + $batch + '""'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $info
        if (-not $process.Start()) { throw "Cannot start $Exe" }
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            & taskkill.exe /PID $process.Id /T /F 2>&1 |
                Out-Null
            return @{
                ExitCode = 124
                Output = "$Exe timed out after $TimeoutSeconds s"
            }
        }
        $text = ''
        for ($i = 0; $i -lt 20; $i++) {
            try {
                $text = $(if (Test-Path $stdout) { [IO.File]::ReadAllText($stdout) }else { '' }) + $(if (Test-Path $stderr) { [IO.File]::ReadAllText($stderr) }else { '' })
                break
            } catch [IO.IOException] { Start-Sleep -Milliseconds 100 }
        }
        return @{ExitCode = $process.ExitCode; Output = $text.TrimEnd() }
    } finally {
        if ($process) { $process.Dispose() }
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-PASSshWithPassword {
    <# Runs ssh.exe once with a password sign-in and returns @{ExitCode;Output}. The password reaches ssh
       through SSH_ASKPASS and an environment variable of this process only: it never appears on a command
       line or in a file. -Arguments are the ssh options, the target and the remote command. #>
    param([pscredential]$Credential, [string[]]$Arguments, [int]$TimeoutSeconds = 90)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('paseasy-askpass-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force |
        Out-Null
    $askpass = Join-Path $tmp 'askpass.cmd'
    [IO.File]::WriteAllText($askpass, "@echo off`r`npowershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"[Console]::Out.Write(`$env:PASEASY_ASKPASS)`"`r`n")
    $saved = @{}
    foreach ($n in @('SSH_ASKPASS', 'SSH_ASKPASS_REQUIRE', 'DISPLAY', 'PASEASY_ASKPASS')) {
        $saved[$n] = [Environment]::GetEnvironmentVariable($n, 'Process')
    }
    try {
        [Environment]::SetEnvironmentVariable('SSH_ASKPASS', $askpass, 'Process')
        [Environment]::SetEnvironmentVariable('SSH_ASKPASS_REQUIRE', 'force', 'Process')
        [Environment]::SetEnvironmentVariable('DISPLAY', 'paseasyinstall:0', 'Process')
        [Environment]::SetEnvironmentVariable('PASEASY_ASKPASS', $Credential.GetNetworkCredential().Password, 'Process')
        $passwordOnly = @('-o', 'BatchMode=no', '-o', 'PubkeyAuthentication=no', '-o', 'PreferredAuthentications=password,keyboard-interactive', '-o', 'NumberOfPasswordPrompts=1')
        return Invoke-PASNativeQuiet 'ssh.exe' ($passwordOnly + $Arguments) $TimeoutSeconds
    } finally {
        foreach ($n in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($n, $saved[$n], 'Process')
        }
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-PASSshPasswordSignIn {
    <# Read-only check for Test-PASPreflight: signs in to a Linux server with the password, the way the
       first installation does, and reads the user id and /etc/os-release. Authorises no key and writes
       nothing on the server. Returns @{Checked;ExitCode;Output;Detail}.
       Host key: the known_hosts file of the configuration when it knows the server; otherwise, Lab only,
       the key is accepted for this one connection (a temporary file, deleted afterwards). #>
    param($HostRecord, [pscredential]$Credential, [bool]$Lab)
    $address = [string]$HostRecord.address
    $port = ''
    if ($HostRecord.Contains('port') -and $HostRecord.port) {
        $port = [string][int]$HostRecord.port
    }
    $knownName = $address
    if ($port -and $port -ne '22') {
        $knownName = '[' + $address + ']:' + $port
    }
    $known = [string](Get-PASValue $HostRecord 'knownHostsFile' '')
    $isKnown = $false
    if ($known -and (Test-Path -LiteralPath $known -PathType Leaf)) {
        $isKnown = ((Invoke-PASNativeQuiet 'ssh-keygen.exe' @('-F', $knownName, '-f', $known)).ExitCode -eq 0)
    }
    if (-not $isKnown -and -not $Lab) {
        return @{ Checked = $false; Detail = "Not checked: the SSH host key of $address is not in the known_hosts file of the configuration, and the Secure profile sends no password to an unverified server." }
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('paseasy-hostkey-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force |
        Out-Null
    try {
        $hostKeyOptions = @('-o', 'StrictHostKeyChecking=yes', '-o', ('UserKnownHostsFile=' + $known))
        if (-not $isKnown) {
            $hostKeyOptions = @('-o', 'StrictHostKeyChecking=accept-new', '-o', ('UserKnownHostsFile=' + (Join-Path $tmp 'known_hosts')))
        }
        $arguments = $hostKeyOptions + @('-o', 'LogLevel=ERROR', '-o', 'ConnectTimeout=15', '-n')
        if ($port) {
            $arguments += @('-p', $port)
        }
        $arguments += @(([string]$HostRecord.user + '@' + $address), 'id -u; cat /etc/os-release')
        $result = Invoke-PASSshWithPassword -Credential $Credential -Arguments $arguments -TimeoutSeconds 60
        return @{ Checked = $true; ExitCode = $result.ExitCode; Output = [string]$result.Output }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-PASSshRoot {
    <# Linux stages install packages, write /opt/paeasyinstall and systemd units: they run as root. Checked
       right after key sign-in works, so a non-root account fails here with a clear message instead of
       halfway through the media upload. #>
    param([string]$Key, [object[]]$Base, [string]$User, [string]$Address)
    $r = Invoke-PASNativeQuiet 'ssh.exe' (@('-i', $Key, '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes') + $Base + @(($User + '@' + $Address), 'id -u'))
    $uid = ([string]$r.Output).Trim()
    if ($r.ExitCode -ne 0 -or $uid -ne '0') {
        throw "PASeasyInstall signs in to Linux servers as root, but $User@$Address is not root (uid '$uid'). Use the root account: allow root to sign in with its password once (for example 'PermitRootLogin yes' while you install), or authorise the controller key for root."
    }
}

function Invoke-PASSshBootstrap {
    <# Makes key-based SSH work for one Linux server:
         1. the controller key exists (generated once per environment, private to this user);
         2. the server's host key is known (Lab: accepted on first use and logged as a deviation;
            Secure: must already be in the known_hosts file);
         3. if the key is not yet authorised, the server password (from the UI/CredentialMap) is used
            once, through SSH_ASKPASS, to append the public key to the account's authorized_keys.
       The password never appears on a command line or in a file. #>
    param([string]$HostId, $HostRecord, [pscredential]$Credential, [bool]$Lab, [string]$Directory)
    $addr = [string]$HostRecord.address
    $user = [string]$HostRecord.user
    $port = ''
    if ($HostRecord.Contains('port') -and $HostRecord.port) { $port = [string][int]$HostRecord.port }
    $knownName = if ($port -and $port -ne '22') { '[' + $addr + ']:' + $port }else { $addr }
    $key = [string]$HostRecord.identityFile
    $known = [string]$HostRecord.knownHostsFile
    if (-not $key -or -not $known) { throw "Linux server $HostId needs identityFile and knownHostsFile" }
    foreach ($d in @([IO.Path]::GetDirectoryName($key), [IO.Path]::GetDirectoryName($known))) {
        if (-not(Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force |
                Out-Null
        }
    }
    if (-not(Test-Path -LiteralPath $key -PathType Leaf)) {
        $r = Invoke-PASNativeQuiet 'ssh-keygen.exe' @('-q', '-t', 'ed25519', '-N', '', '-C', ('paseasyinstall@' + $env:COMPUTERNAME), '-f', $key)
        if ($r.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $key)) { throw "Cannot create the controller SSH key: $($r.Output)" }
        Write-PASRunEvent $Directory 'SshKeyCreated' "Created controller SSH key $key" $HostId
    }
    if (-not(Test-Path -LiteralPath $known -PathType Leaf)) { [IO.File]::WriteAllText($known, '') }
    $r = Invoke-PASNativeQuiet 'ssh-keygen.exe' @('-F', $knownName, '-f', $known)
    if ($r.ExitCode -ne 0) {
        if (-not $Lab) { throw "SSH host key of $addr is not in $known. Add the verified host key (Secure profile never trusts on first use)." }
        # Trust on first use: one key-exchange-only probe records the ed25519 host key (authentication
        # is not attempted). ssh-keyscan is avoided: it can hang on Windows OpenSSH.
        $tofu = @('-o', 'StrictHostKeyChecking=accept-new', '-o', ('UserKnownHostsFile=' + $known), '-o', 'HostKeyAlgorithms=ssh-ed25519', '-o', 'BatchMode=yes',
            '-o', 'PreferredAuthentications=none', '-o', 'ConnectTimeout=15', '-n')
        if ($port) { $tofu += @('-p', $port) }
        $null = Invoke-PASNativeQuiet 'ssh.exe' ($tofu + @(($user + '@' + $addr), 'true'))
        $r = Invoke-PASNativeQuiet 'ssh-keygen.exe' @('-F', $knownName, '-f', $known)
        if ($r.ExitCode -ne 0) { throw "Cannot read the SSH host key of $addr" }
        $fp = (Invoke-PASNativeQuiet 'ssh-keygen.exe' @('-l', '-F', $knownName, '-f', $known)).Output
        Write-PASRunEvent $Directory 'Warning' ("SECURITY DEVIATION (Lab): trusted SSH host key of $addr on first use. " + (($fp -split "`n" | Where-Object { $_ -match 'SHA256' }) -join ' ')) $HostId 'ssh-bootstrap' 'Warning'
    }
    $base = @('-o', 'StrictHostKeyChecking=yes', '-o', ('UserKnownHostsFile=' + $known), '-o', 'ConnectTimeout=15', '-n')
    if ($port) { $base += @('-p', $port) }
    $probe = Invoke-PASNativeQuiet 'ssh.exe' (@('-i', $key, '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes') + $base + @(($user + '@' + $addr), 'true'))
    if ($probe.ExitCode -eq 0) {
        Assert-PASSshRoot $key $base $user $addr
        Write-PASRunEvent $Directory 'TaskCompleted' "Key-based SSH to $user@$addr works" $HostId 'ssh-bootstrap'
        return
    }
    $pub = ([IO.File]::ReadAllText($key + '.pub')).Trim()
    if (-not $Credential -or
        $Credential.Password.Length -eq 0) { throw "Key-based SSH to $user@$addr is not authorised and no password was given. Authorise this key for $user on the server: $pub" }
    if ($pub -notmatch '^ssh-ed25519 [A-Za-z0-9+/=]+ [A-Za-z0-9@._-]+$') { throw 'Unexpected controller public key format' }
    $cmd = "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && (grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys)"
    $r = Invoke-PASSshWithPassword -Credential $Credential -Arguments ($base + @(($user + '@' + $addr), $cmd))
    if ($r.ExitCode -ne 0) { throw "Password sign-in to $user@$addr failed (the server may refuse password logins for $user). Authorise this key for $user on the server instead: $pub" }
    $probe = Invoke-PASNativeQuiet 'ssh.exe' (@('-i', $key, '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes') + $base + @(($user + '@' + $addr), 'true'))
    if ($probe.ExitCode -ne 0) { throw "The controller key was added for $user@$addr but key sign-in still fails: $($probe.Output)" }
    Assert-PASSshRoot $key $base $user $addr
    Write-PASRunEvent $Directory 'TaskCompleted' "Authorised the controller key for $user@$addr (password used once, not stored)" $HostId 'ssh-bootstrap'
}

function ConvertFrom-PASOsRelease {
    <# Parses /etc/os-release text (KEY=value, value optionally quoted) into a hashtable. #>
    param([string]$Text)
    $o = @{}
    foreach ($l in @($Text -split "`n")) {
        if ($l -match '^\s*([A-Z_][A-Z0-9_]*)=(.*)$') {
            $v = $Matches[2].Trim()
            if ($v.Length -ge 2 -and
                $v[0] -eq $v[-1] -and
                $v[0] -in @([char]'"', [char]"'")) { $v = $v.Substring(1, $v.Length - 2) }
            $o[$Matches[1]] = $v
        }
    }
    return $o
}

function Get-PASPsmpVariantForOs {
    <# Maps /etc/os-release ID, VERSION_ID and ID_LIKE to the vendor's PSMP package variant name. #>
    param([string]$Id, [string]$VersionId, [string]$IdLike)
    $major = ([string]$VersionId -split '\.')[0]
    if ($Id -eq 'ubuntu' -and $major -in @('22', '24')) { return 'Ubuntu' + $major }
    if (($Id -in @('rhel', 'rocky', 'almalinux', 'centos', 'ol') -or
            $IdLike -match '(^|\s)rhel(\s|$)') -and
        $major -in @('8', '9')) { return 'RHELinux' + $major }
    if ($Id -match '^sles' -and $major -eq '15') { return 'SLES15' }
    return ''
}

function Select-PASPsmpMediaForHost {
    <# The selected PSMP package is for one distribution. Once key-based SSH works, read the server's OS and,
       if it differs, use the package for that distribution from the same bundle or folder. Stops before any
       upload when no matching package is available. #>
    param($Component, $HostRecord, [string]$Directory, [string]$DataRoot)
    $media = [string]$Component.media
    $name = [IO.Path]::GetFileName($media)
    $have = Get-PASMediaVariant 'PSMP' $name
    if (-not $have) { return }
    $base = @('-i', [string]$HostRecord.identityFile, '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'StrictHostKeyChecking=yes', '-o', ('UserKnownHostsFile=' + [string]$HostRecord.knownHostsFile), '-o', 'ConnectTimeout=15', '-n')
    if ($HostRecord.Contains('port') -and $HostRecord.port) { $base += @('-p', [string][int]$HostRecord.port) }
    # Plain command: the SSH tool wrapper refuses quotes in arguments; the file is parsed here.
    $r = Invoke-PASNativeQuiet 'ssh.exe' ($base + @(([string]$HostRecord.user + '@' + [string]$HostRecord.address), 'cat /etc/os-release'))
    $os = ConvertFrom-PASOsRelease ([string]$r.Output)
    $osId = [string]$os['ID']
    $osVer = [string]$os['VERSION_ID']
    if ($r.ExitCode -ne 0 -or -not $osId) { throw "Cannot read the operating system of $($HostRecord.address): $($r.Output)" }
    $want = Get-PASPsmpVariantForOs $osId $osVer ([string]$os['ID_LIKE'])
    $pretty = if ($os['PRETTY_NAME']) { [string]$os['PRETTY_NAME'] }else { "$osId $osVer" }
    if (-not $want) { throw "PSMP does not support $pretty on $($HostRecord.address) (supported: Ubuntu 22/24, RHEL-family 8/9, SLES 15)." }
    if ($want -eq $have) { return }
    $wantName = $name -replace ('(?i)SSHProxy-' + [regex]::Escape($have) + '-'), ('SSHProxy-' + $want + '-')
    $found = ''
    $src = $null
    if ($Component.Contains('mediaSource')) { $src = $Component.mediaSource }
    if ($src -and $src.entry) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $entryWant = ($src.entry -replace ('(?i)SSHProxy-' + [regex]::Escape($have) + '-'), ('SSHProxy-' + $want + '-'))
        $zip = [IO.Compression.ZipFile]::OpenRead([string]$src.path)
        try { $hit = @($zip.Entries | Where-Object { $_.FullName -eq $entryWant }).Count -eq 1 }finally { $zip.Dispose() }
        if ($hit) { $found = Resolve-PASMediaItemPath ([pscustomobject]@{Path = [string]$src.path; Entry = $entryWant }) $DataRoot }
    } else {
        $folder = if ($src -and $src.path) { [IO.Path]::GetDirectoryName([string]$src.path) }else { [IO.Path]::GetDirectoryName($media) }
        $candidate = Join-Path $folder $wantName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $found = $candidate }
    }
    if (-not $found) { throw "The selected PSMP package $name is for $have, but $($HostRecord.address) runs $pretty. Add the $want package ($wantName) to the media folder." }
    $Component.media = $found
    Write-PASRunEvent $Directory 'TaskCompleted' "Using $([IO.Path]::GetFileName($found)) for $pretty" ([string]$Component.id) 'media-select'
}

function New-PASManagementSession {
    param($Configuration, [string]$HostId, [pscredential]$Credential)
    $h = $Configuration.hosts[$HostId]
    $useSsl = $true
    $ov = $Configuration.security.overrides
    $lab = ([string]$Configuration.security.profile -eq 'Lab')
    if ($lab -and $ov.Contains('WinRM.RequireHTTPS')) { $useSsl = [bool]$ov['WinRM.RequireHTTPS'] }
    if ($h.Contains('useSsl')) { $useSsl = [bool]$h.useSsl }
    $opt = @{}
    if ($lab -and $ov.Contains('WinRM.SkipCACheck') -and [bool]$ov['WinRM.SkipCACheck']) { $opt.SkipCACheck = $true }
    if ($lab -and $ov.Contains('WinRM.SkipCNCheck') -and [bool]$ov['WinRM.SkipCNCheck']) { $opt.SkipCNCheck = $true }
    $last = $null
    foreach ($endpoint in @('PASeasyInstall.Management', 'Microsoft.PowerShell')) {
        try {
            $p = @{
                ComputerName = [string]$h.address
                Credential = $Credential
                Authentication = 'Negotiate'
                ConfigurationName = $endpoint
                SessionOption = (New-PSSessionOption @opt)
                ErrorAction = 'Stop'
            }
            if ($useSsl) { $p.UseSSL = $true }
            return (New-PSSession @p)
        } catch { $last = $_ }
    }
    throw "Cannot open a management session to $HostId ($($h.address)): $($last.Exception.Message)"
}

function Get-PASPvwaTrustBundle {
    <# What a CPM of this deployment must trust: the HTTPS certificate of every PVWA in the configuration.
       With one PVWA it is that certificate file. With several it is a PKCS#7 bundle of all of them
       (public certificates only), stored in the run directory. Returns @{File;SHA256}. #>
    param($Configuration, [string]$PvwaId, [hashtable]$Credentials, [string]$Directory)
    $ids = @($PvwaId)
    $ids += @($Configuration.components | Where-Object { $_ -and $_.type -eq 'PVWA' -and [string]$_.id -ne $PvwaId } | ForEach-Object { [string]$_.id })
    $first = Get-PASPvwaCertificate -Configuration $Configuration -PvwaId $PvwaId -Credentials $Credentials -Directory $Directory
    if ($ids.Count -eq 1) {
        return $first
    }
    $file = Join-Path $Directory 'pvwa-trust-bundle.p7b'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        $collection = [Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
        foreach ($id in $ids) {
            $one = Get-PASPvwaCertificate -Configuration $Configuration -PvwaId $id -Credentials $Credentials -Directory $Directory
            [void]$collection.Add([Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes([string]$one.File)))
        }
        [IO.File]::WriteAllBytes($file, $collection.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs7))
    }
    return @{ File = $file; SHA256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
}
function Get-PASPvwaCertificate {
    <# Reads the certificate bound to PVWA's HTTPS port from the PVWA server itself (authenticated),
       stores the public DER in the run directory and returns @{File;SHA256}. While PVWA is still being
       installed nothing is bound yet: then it is the certificate that stage Certificate put into the machine
       store (the lab certificate of this component, or the one named by tlsCertificateThumbprint), which
       ConfigureTLS binds later. #>
    param($Configuration, [string]$PvwaId, [hashtable]$Credentials, [string]$Directory)
    $file = Join-Path $Directory ('pvwa-trust-' + $PvwaId + '.cer')
    if (Test-Path -LiteralPath $file -PathType Leaf) {
        # Captured earlier in this run: every CPM of the run pins the same file, also after a resume.
        return @{ File = $file; SHA256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
    }
    $e = @($Configuration.components | Where-Object { $_.id -eq $PvwaId })[0]
    $hostId = [string]$e.host
    $cred = $Credentials[$hostId]
    if (-not $cred) { $cred = $Credentials[$PvwaId] }
    if (-not $cred) { throw "No credential for PVWA server $hostId" }
    $configured = [string](Get-PASValue (Get-PASValue $e 'options' $null) 'tlsCertificateThumbprint' '')
    $owned = 'PASeasyInstall:' + $PvwaId + ':PVWA:LabTLS'
    $s = New-PASManagementSession -Configuration $Configuration -HostId $hostId -Credential $cred
    try {
        $b64 = Invoke-Command -Session $s -ErrorAction Stop -ArgumentList $configured, $owned -ScriptBlock {
            param([string]$Configured, [string]$Owned)
            $thumb = $null
            $store = 'My'
            try {
                Import-Module WebAdministration -ErrorAction Stop
                $b = @(Get-ChildItem IIS:\SslBindings -ErrorAction Stop | Where-Object { $_.Port -eq 443 }) | Select-Object -First 1
                if ($b) {
                    $thumb = [string]$b.Thumbprint
                    if ($b.Store) { $store = [string]$b.Store }
                }
            } catch {}
            if (-not $thumb) {
                $out = (& netsh.exe http show sslcert ipport=0.0.0.0:443) -join "`n"
                if ($out -match 'Certificate Hash\s*:\s*([0-9a-fA-F]{40})') { $thumb = $Matches[1] }
                if ($out -match 'Certificate Store Name\s*:\s*(\S+)' -and $Matches[1] -ne '(null)') { $store = $Matches[1] }
            }
            if (-not $thumb -and $Configured) {
                $thumb = ($Configured -replace '\s', '').ToUpperInvariant()
            }
            if (-not $thumb) {
                $mine = @(Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -ceq $Owned })
                if ($mine.Count -eq 1) {
                    $thumb = [string]$mine[0].Thumbprint
                }
            }
            if (-not $thumb) { throw 'PVWA has no certificate bound to HTTPS port 443 and none prepared for it' }
            $cert = Get-Item -LiteralPath ('Cert:\LocalMachine\' + $store + '\' + $thumb) -ErrorAction Stop
            [Convert]::ToBase64String($cert.RawData)
        }
    } finally { Remove-PSSession $s -ErrorAction SilentlyContinue }
    $bytes = [Convert]::FromBase64String([string]$b64)
    [IO.File]::WriteAllBytes($file, $bytes)
    $sha = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    $subject = ([Security.Cryptography.X509Certificates.X509Certificate2]::new($bytes)).Subject
    Write-PASRunEvent $Directory 'PVWATrustCaptured' "Captured $PvwaId HTTPS certificate $subject (SHA256 $sha) for CPM pinning" $PvwaId
    return @{File = $file; SHA256 = $sha }
}
