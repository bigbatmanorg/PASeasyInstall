# Public PTA deployment continuation. Trust material is public; private keys never enter this path.
function Get-PASeasyPTATrustBundle {
    param([hashtable]$Target,[string]$ExpectedSHA256)
    if($ExpectedSHA256 -notmatch '^[A-Fa-f0-9]{64}$'){throw 'PTA TLS checkpoint has no approved public trust digest'}
    $stage=[string]$Target.ComponentStageRoot
    if($stage -notmatch '^/opt/paeasyinstall/components/[a-z][a-z0-9_-]{0,39}$'){throw 'Unqualified PTA certificate workspace'}
    $code=@'
set -eu
p=__PATH__/certificates/trust-bundle.pem
for parent in / /opt /opt/paeasyinstall /opt/paeasyinstall/components __PATH__ __PATH__/certificates; do
    [ -d "$parent" ] && [ ! -L "$parent" ] && [ "$(stat -c %u "$parent")" = 0 ]
    mode=$(stat -c %a "$parent"); [ "$((8#$mode & 022))" = 0 ]
done
[ -f "$p" ] && [ ! -L "$p" ] && [ "$(stat -c %u "$p")" = 0 ]
mode=$(stat -c %a "$p"); [ "$((8#$mode & 022))" = 0 ]
size=$(stat -c %s "$p"); [ "$size" -ge 100 ] && [ "$size" -le 65536 ]
set +e
grep -q 'PRIVATE KEY' "$p"
grep_status=$?
set -e
[ "$grep_status" = 1 ]
hash=$(sha256sum "$p" | cut -d' ' -f1)
[ "$hash" = '__EXPECTED__' ]
data=$(head -c 65537 "$p" | base64 -w0)
jq -nc --arg hash "$hash" --arg data "$data" --argjson size "$size" '{Hash:$hash,Base64:$data,Bytes:$size}'
'@
    $result=ConvertTo-PASeasyHashtable (ConvertFrom-Json -InputObject (Invoke-PSLinuxControl $Target ($code.Replace('__PATH__',$stage).Replace('__EXPECTED__',$ExpectedSHA256.ToLowerInvariant()))))
    $bytes=[Convert]::FromBase64String([string]$result.Base64)
    if($bytes.Length -lt 100 -or $bytes.Length -gt 65536 -or $bytes.Length -ne [int]$result.Bytes){throw 'PTA public certificate transfer size mismatch'}
    $hash=[Security.Cryptography.SHA256]::Create()
    try{$actual=([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','')}finally{$hash.Dispose()}
    if($actual -ine $ExpectedSHA256 -or $actual -ine [string]$result.Hash){throw 'PTA public trust bundle changed after its TLS checkpoint'}
    $text=[Text.Encoding]::ASCII.GetString($bytes)
    if($text -match 'PRIVATE KEY' -or $text -notmatch '-----BEGIN CERTIFICATE-----'){throw 'PTA may transfer only public certificates'}
    return [pscustomobject]@{Base64=[Convert]::ToBase64String($bytes);SHA256=$actual;Bytes=$bytes.Length}
}
function Invoke-PASeasyPTAVaultSyslog {
    param([hashtable]$Config,[hashtable]$Component,[hashtable]$ComponentInventory,[string]$RunId,[string]$DataRoot,[hashtable]$Credentials,[hashtable]$Secrets)
    $hostId=Get-PASeasyPTASyslogHost $Config
    if(-not $hostId){return}
    if(-not $Credentials.ContainsKey($hostId) -or $Credentials[$hostId] -isnot [pscredential]){throw "PTA syslog requires primary Windows credentials for '$hostId'"}
    $hostInfo=$Config.hosts[$hostId]
    $primary=@(Get-PASeasyResourceIdentity ([string]$Config.vault.address)|Sort-Object -Unique)
    $management=@(Get-PASeasyResourceIdentity ([string]$hostInfo.address)|Sort-Object -Unique)
    if($primary.Count -ne 1 -or $management.Count -ne 1 -or $primary[0] -ne $management[0]){throw 'PTA management host does not uniquely resolve to the configured primary Vault'}
    $dir=Get-PASeasyRunDirectory $RunId $DataRoot
    $state=Read-PASJson (Join-Path (Join-Path $dir ([string]$Component.id)) 'state.json')
    $tlsStep=Get-PASProp (Get-PASProp $state 'steps' $null) 'configuretls' $null
    if((Get-PASProp $tlsStep 'status' '') -ne 'Succeeded'){throw 'PTA TLS configuration has no successful checkpoint; refusing Vault mutation'}
    $tls=Get-PASProp $tlsStep 'data' $null
    $expected=[string](Get-PASProp $tls 'TrustBundleSHA256' '')
    $linux=$ComponentInventory.Targets[[string]$Component.id].Clone()
    $linux.ComponentStageRoot=[string]$ComponentInventory.Values.Components[[string]$Component.id].StageRoot
    $bundle=Get-PASeasyPTATrustBundle $linux $expected
    $id=[string]$Component.id+'-vault-syslog'
    $payload=Join-Path (Join-Path $dir 'Payloads') $id
    New-Item $payload -ItemType Directory -Force|Out-Null
    foreach($entry in @(@{From='Tasks/Vault/Configure-PTASyslog.ps1';To='Configure.ps1'},@{From='Tasks/Verify/Verify-PTASyslog.ps1';To='Verify.ps1'})){
        Copy-Item -LiteralPath (Get-PASRecipePath ('Recipes/Vault/'+$entry.From)) -Destination (Join-Path $payload $entry.To) -Force
    }
    $target=@{Protocol='WinRM';Runtime='WindowsPowerShell';ComputerName=[string]$hostInfo.address;CredentialRef=$hostId;UseSSL=$true;Port=5986;ConfigurationName=[string](Get-PASeasyProperty $Config.vault 'managementEndpoint' 'PAExec.Management');StageRoot='C:\ProgramData\PAExec';LockKey=('host-'+$primary[0]);ConnectRetrySeconds=120}
    if($Config.security.profile -eq 'Lab'){
        if($Config.security.overrides.Contains('WinRM.RequireHTTPS') -and -not $Config.security.overrides['WinRM.RequireHTTPS']){$target.UseSSL=$false;$target.Port=5985}
        foreach($flag in @('WinRM.SkipCACheck','WinRM.SkipCNCheck')){if($Config.security.overrides.Contains($flag)){$target[$flag.Replace('WinRM.','')]=[bool]$Config.security.overrides[$flag]}}
    }
    $settings=@{Address=[string]$Config.hosts[[string]$Component.host].address;VaultAddress=$primary[0];Port=514;ServerRoot=[string](Get-PASeasyProperty $Config.vault 'serverRoot' 'C:\Program Files (x86)\PrivateArk\Server');TrustBundleBase64=$bundle.Base64;TrustBundleSHA256=$bundle.SHA256;TranslatorSHA256='94D0908FA6019CD0671F7DEAD17EAEF75B50D97ED839DA0C519AB9078158FCB8';TranslatorImportSHA256='83CAC4EBCBDDF281DC2F5FA1F10C6E3431ABA8714541E3255DDE9517EAF95985'}
    $inventory=@{SchemaVersion=1;Targets=@{};Values=@{Syslog=$settings}};$inventory.Targets[$id]=$target
    $workflow=@{SchemaVersion=1;Name='PTA primary TLS audit configuration';Target=$id;Steps=@(@{Id='configure-syslog';Script='Configure.ps1';Verify='Verify.ps1';Mode='Detached';Critical=$true;RequiresVaultSession=$true;Inputs=@{Settings=@{ConfigRef='Values.Syslog'}};TimeoutSeconds=600})}
    $wf=Join-Path $payload 'workflow.psd1';$inv=Join-Path $payload 'inventory.psd1'
    [IO.File]::WriteAllText($wf,(ConvertTo-PASLiteral $workflow),[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($inv,(ConvertTo-PASLiteral $inventory),[Text.UTF8Encoding]::new($false))
    $hostGate=Enter-PASeasyGate -Name ('host-'+$primary[0]) -DataRoot $DataRoot -RunId $RunId -TimeoutSeconds 180
    try{
        Write-PASeasyRunEvent $dir 'PTASyslog' 'Applying pinned public CA and native primary TLS audit configuration; receiver ingestion remains a separate functional check' ([string]$Component.id)
        Invoke-PAExecRun -WorkflowPath $wf -InventoryPath $inv -StateRoot (Join-Path $DataRoot 'Runs') -RunId $RunId -Credentials $Credentials -Secrets $Secrets -Resume:(Test-Path (Join-Path (Join-Path $dir $id) 'state.json')) -VaultSessionAddress ([string]$Config.vault.address) -CoordinationDataRoot $DataRoot|Out-Null
        if(-not $hostGate.PreexistingClaim){$hostGate.Complete()}
    }finally{$hostGate.Dispose()}
}
