# Key-specific logic; expanded only into the shipped generator and verifier.
function Assert-PASeasyKeyGeneratorIdentity {
    if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18'){throw 'Key generation requires the durable SYSTEM worker'}
}
function Get-PASeasyKeyNames { @('server.key','recprv.key','recpub.key','rndbase.dat') }
function Assert-PASeasyKeyDirectory {
    param([string]$Path)
    $null=Get-PASeasyVaultCanonicalPath $Path
    Assert-PASeasyVaultAncestors $Path
    $null=Assert-PASeasyVaultEntry $Path -Directory -Protected
    Assert-PASeasyVaultTree $Path -Protected -AllowInheritedDescendants
}
function Read-PASeasyKeyJson {
    param([string]$Path)
    $item=Assert-PASeasyVaultEntry $Path -Protected
    if($item.PSIsContainer -or $item.Length -lt 2 -or $item.Length -gt 16384){throw 'Key generation metadata length is invalid'}
    try{[IO.File]::ReadAllText($Path)|ConvertFrom-Json -ErrorAction Stop}catch{throw 'Key generation metadata is invalid; explicit reconciliation required'}
}
function Test-PASeasyKeyReceipt {
    param([hashtable]$Settings)
    Assert-PASeasyKeyDirectory $Settings.KeysDir
    $receipt=Read-PASeasyKeyJson (Join-Path $Settings.KeysDir '.paeasy-key-generation.json')
    $claim=Read-PASeasyKeyJson (Join-Path $Settings.KeysDir '.paeasy-key-generation.claim.json')
    if($receipt.schemaVersion -ne 1 -or $claim.schemaVersion -ne 1 -or $receipt.generationId -cnotmatch '^[a-f0-9]{32}$' -or $claim.generationId -cne $receipt.generationId -or $receipt.toolSHA256 -cnotmatch '^[A-F0-9]{64}$' -or $claim.toolSHA256 -cne $receipt.toolSHA256){throw 'Key generation receipt identity is invalid'}
    $records=@($receipt.files)
    if($records.Count -ne 4){throw 'Key generation receipt must describe exactly four files'}
    foreach($name in @(Get-PASeasyKeyNames)){
        $record=@($records|Where-Object {$_.name -ceq $name})
        if($record.Count -ne 1 -or $record[0].length -isnot [long] -and $record[0].length -isnot [int] -or $record[0].length -le 0 -or $record[0].length -gt 1048576 -or $record[0].sha256 -cnotmatch '^[A-F0-9]{64}$'){throw 'Key generation receipt file descriptor is invalid'}
        $path=Join-Path $Settings.KeysDir $name
        $item=Assert-PASeasyVaultEntry $path -Protected
        if($item.PSIsContainer -or $item.Length -ne $record[0].length -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne $record[0].sha256){throw 'Published key material differs from its trusted receipt'}
    }
    $true
}
function Invoke-PASeasyKeyNative {
    param([string]$Tool,[string]$Directory,[int]$TimeoutSeconds=300)
    $stdout=Join-Path $Directory 'native.stdout';$stderr=Join-Path $Directory 'native.stderr'
    $process=$null;$stage='Launch';$code=$null;$stdoutLength=-1L;$stderrLength=-1L;$phraseMatched=$false
    try{
        $process=Start-Process -FilePath $Tool -ArgumentList @('AES-256','RSA-2048','.','/d') -WorkingDirectory $Directory -NoNewWindow -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
        # Windows PowerShell5.1 Start-Process can lose the native exit status if
        # WaitForExit opens/releases the process handle lazily. Pin it BEFORE any
        # wait/property polling; a success phrase never substitutes for exit0.
        $stage='PinProcessHandle';$nativeHandle=$process.Handle
        if($nativeHandle -eq [IntPtr]::Zero){throw 'Native process handle unavailable'}
        $stage='Wait';$deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        do{
            foreach($path in @($stdout,$stderr)){if(Test-Path -LiteralPath $path){$item=Assert-PASeasyVaultEntry $path -Protected -AllowInherited;if($item.Length -gt 1048576){throw 'PAKeyGen output exceeded its private bound'}}}
            if($process.WaitForExit(200)){break}
            if([DateTime]::UtcNow -ge $deadline){throw 'PAKeyGen timed out; private partial state retained'}
        }while($true)
        $stage='ReadExit';$code=$process.ExitCode
        if($code -isnot [int]){throw 'Native exit status unavailable'}
        $stage='ReadOutput'
        foreach($path in @($stdout,$stderr)){$item=Assert-PASeasyVaultEntry $path -Protected -AllowInherited;if($item.Length -gt 1048576){throw 'PAKeyGen output exceeded its private bound'}}
        $stdoutLength=([IO.FileInfo]::new($stdout)).Length;$stderrLength=([IO.FileInfo]::new($stderr)).Length
        $text=[IO.File]::ReadAllText($stdout)
        $errorText=[IO.File]::ReadAllText($stderr)
        $phraseMatched=[bool]($text -match '(?m)^PAKEYGEN completed successfully\.?\s*$')
        $stage='ValidateExitAndOutput'
        if($code -ne 0 -or -not $phraseMatched -or $errorText.Trim()){throw 'Native contract not satisfied'}
    }catch{
        $exitLabel=if($code -is [int]){[string]$code}else{'Unavailable'}
        # Only fixed stage, typed numeric exit/lengths and a boolean can escape.
        # Never include ErrorRecord, exception text, paths or native output.
        throw ('PAKeyGen native contract failed; stage={0}; exit={1}; stdoutBytes={2}; stderrBytes={3}; successPhrase={4}; private partial state retained' -f $stage,$exitLabel,$stdoutLength,$stderrLength,$phraseMatched)
    }
    finally{if($process){try{if(-not $process.HasExited){$process.Kill();[void]$process.WaitForExit(5000)}}finally{$process.Dispose()}};$text=$null;$errorText=$null}
}
function Invoke-PASeasyKeyGeneration {
    param([hashtable]$Settings)
    Assert-PASeasyKeyGeneratorIdentity
    Assert-PASeasyKeyDirectory $Settings.KeysDir
    $receiptPath=Join-Path $Settings.KeysDir '.paeasy-key-generation.json'
    $claimPath=Join-Path $Settings.KeysDir '.paeasy-key-generation.claim.json'
    if(Test-Path -LiteralPath $receiptPath){$null=Test-PASeasyKeyReceipt $Settings;return [pscustomobject]@{Changed=$false;Message='Protected generated keys match their trusted completion receipt'}}
    if(Test-Path -LiteralPath $claimPath){throw 'Existing key generation intent requires explicit reconciliation; no regeneration performed'}
    foreach($name in @(Get-PASeasyKeyNames)){if(Test-Path -LiteralPath (Join-Path $Settings.KeysDir $name)){throw 'Unmarked or partial key material exists; no adoption, deletion or regeneration performed'}}
    $toolRoot=Join-Path $Settings.AutomationRoot 'PAKeyGen'
    Assert-PASeasyKeyDirectory $toolRoot
    $tool=Join-Path $toolRoot 'PAKeyGen.exe'
    $toolItem=Assert-PASeasyVaultEntry $tool -Protected -AllowInherited
    if($toolItem.PSIsContainer -or $toolItem.Length -le 0){throw 'PAKeyGen executable is unavailable'}
    $toolHash=(Get-FileHash -LiteralPath $tool -Algorithm SHA256).Hash
    $generation=[guid]::NewGuid().ToString('N')
    $work=Join-Path $Settings.AutomationRoot ('PAKeyGen-attempt-'+$generation)
    if(Test-Path -LiteralPath $work){throw 'Key generation workspace already exists'}
    $claim=@{schemaVersion=1;generationId=$generation;toolSHA256=$toolHash}
    Write-PASeasyVaultOwnedFile $claimPath ([Text.Encoding]::UTF8.GetBytes(($claim|ConvertTo-Json -Compress))) -CreateNew
    New-PASeasyVaultDirectory $work
    Invoke-PASeasyKeyNative $tool $work
    Assert-PASeasyKeyDirectory $work
    $records=@()
    foreach($name in @(Get-PASeasyKeyNames)){
        $source=Join-Path (Join-Path $work 'master') $name
        $item=Assert-PASeasyVaultEntry $source -Protected -AllowInherited
        if($item.PSIsContainer -or $item.Length -le 0 -or $item.Length -gt 1048576){throw 'PAKeyGen output file is missing, empty or oversized; partial state retained'}
        $records+=@{name=$name;length=[long]$item.Length;sha256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash}
    }
    foreach($record in $records){
        $bytes=$null
        try{$bytes=[IO.File]::ReadAllBytes((Join-Path (Join-Path $work 'master') $record.name));Write-PASeasyVaultOwnedFile (Join-Path $Settings.KeysDir $record.name) $bytes -CreateNew}
        finally{if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}
    }
    $receipt=@{schemaVersion=1;generationId=$generation;toolSHA256=$toolHash;files=$records}
    Write-PASeasyVaultOwnedFile $receiptPath ([Text.Encoding]::UTF8.GetBytes(($receipt|ConvertTo-Json -Compress -Depth 5))) -CreateNew
    $null=Test-PASeasyKeyReceipt $Settings
    # Only this invocation's private generated copies are removed after verified publication.
    Assert-PASeasyKeyDirectory $work
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop
    [pscustomobject]@{Changed=$true;Message='Four generated keys durably published with a protected completion receipt'}
}
