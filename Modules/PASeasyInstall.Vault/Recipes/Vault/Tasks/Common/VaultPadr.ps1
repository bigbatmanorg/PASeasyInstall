# Manual standby only. Never converts an activated or ambiguous DR into a replica.
function Read-PASeasyPadrIniValue {
    param([string]$Path,[string]$Key,[switch]$Optional)
    $text=[IO.File]::ReadAllText($Path)
    if($text.IndexOf([char]0) -ge 0){throw 'PADR configuration contains NUL bytes; inspection required'}
    $matches=@([regex]::Matches($text,'(?im)^\s*'+[regex]::Escape($Key)+'\s*=([^\r\n]*)'))
    if($matches.Count -eq 0 -and $Optional){return $null}
    if($matches.Count -ne 1){throw "PADR configuration requires exactly one $Key"}
    return $matches[0].Groups[1].Value.Trim()
}
function Assert-PASeasyPadrNotActivated {
    param([hashtable]$Settings)
    $file=Join-Path $Settings.InstallRoot 'PADR\Conf\PADR.ini'
    if((Read-PASeasyPadrIniValue $file 'FailoverMode') -ine 'No'){throw 'DR failover state is not No; refuse automatic return to standby. Preserve DB/config/logs for vendor recovery.'}
    $manual=Read-PASeasyPadrIniValue $file 'ActivateManualFailover' -Optional
    if($null -ne $manual -and $manual -ine 'No'){throw 'DR manual failover trigger is not No; owner-led recovery required'}
    foreach($display in @('PrivateArk Server','CyberArk Logic Container','Cyber-Ark Event Notification Engine')){
        $service=Get-Service -DisplayName $display -ErrorAction Stop
        if($service.Status -ne 'Stopped' -or $service.StartType -ne 'Manual'){throw "DR standby service must be stopped/manual: $display"}
    }
    $db=Get-Service -DisplayName 'PrivateArk Database' -ErrorAction Stop
    if($db.Status -ne 'Running' -or $db.StartType -ne 'Automatic'){throw 'DR database must be running/automatic'}
}
function Assert-PASeasyPadrManualStandby {
    param([hashtable]$Settings)
    Assert-PASeasyPadrNotActivated $Settings
    $conf=Join-Path $Settings.InstallRoot 'PADR\Conf'
    foreach($pair in @(@('EnableFailover','No'),@('EnableCheck','Yes'),@('EnableReplicate','Yes'))){
        if((Read-PASeasyPadrIniValue (Join-Path $conf 'PADR.ini') $pair[0]) -ine $pair[1]){throw "PADR $($pair[0]) must be $($pair[1])"}
    }
    $expected=[Net.IPAddress]::Parse([string]$Settings.PrimaryIP).ToString()
    if((Read-PASeasyPadrIniValue (Join-Path $conf 'Vault.ini') 'ADDRESS') -ne $expected){throw 'DR primary address mismatch'}
}
function Set-PASeasyPadrIniValue {
    param([string]$Path,[string]$Key,[string]$Value)
    # Require a single native key; never normalize duplicate/partial configuration silently.
    $old=Read-PASeasyPadrIniValue $Path $Key
    if($old -ieq $Value){return $false}
    $text=[IO.File]::ReadAllText($Path)
    $pattern='(?im)^\s*'+[regex]::Escape($Key)+'\s*=[^\r\n]*'
    $updated=[regex]::Replace($text,$pattern,$Key+'='+$Value)
    $bytes=[Text.Encoding]::Default.GetBytes($updated)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {$stream.SetLength(0);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    if((Read-PASeasyPadrIniValue $Path $Key) -ine $Value){throw "PADR $Key write could not be verified"}
    return $true
}
