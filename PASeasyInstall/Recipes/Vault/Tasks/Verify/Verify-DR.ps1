# Read-only DR acceptance (oracle verification.interpret): standby services, configuration, a recent
# completed PADR cycle and ongoing metadata replication in the current PADR session, no later errors.
param([Parameter(Mandatory=$true)][hashtable]$Settings,[int]$MaxAgeSeconds=7500,[switch]$Restart,[int]$Minutes=0,[string]$RunId='',[switch]$TestSafe)
$SafeName=''; if($TestSafe){ if(-not $RunId){throw 'TestSafe requires RunId'}; $SafeName='PAExecRepl'+$RunId.Substring(0,[Math]::Min(12,$RunId.Length)) }
$issues=@();$evidence=@()
# PAEASY_INCLUDE_VAULT_PADR
try {Assert-PASeasyPadrManualStandby $Settings;$evidence+='EnableFailover=No; FailoverMode=No; native standby services verified'}catch{$issues+=$_.Exception.Message}
$padr=Get-Service -DisplayName 'CyberArk Vault Disaster Recovery' -ErrorAction SilentlyContinue
if(-not $padr -or $padr.Status -ne 'Running' -or $padr.StartType -ne 'Automatic'){$issues+='PADR service not running/automatic'}
$root=Join-Path $Settings.InstallRoot 'PADR'
$log=Join-Path $root 'Logs\padr.log'
if(-not(Test-Path -LiteralPath $log)){$issues+='PADR log missing'}else{
    $lines=@(Get-Content -LiteralPath $log -Tail 2000)
    $start=0;$lastCycle=-1;$lastMetadata=-1
    for($i=0;$i -lt $lines.Count;$i++){
        if($lines[$i] -match 'PADR0200I'){$start=$i}
        if($lines[$i] -match 'PADR0010I'){$lastCycle=$i}
        if($lines[$i] -match 'PADR0099I'){$lastMetadata=$i}
    }
    if($lastCycle -lt $start -or $lastCycle -lt 0){$issues+='No completed replication cycle in current PADR session'}
    if($lastMetadata -lt $start){$issues+='No metadata replication in current PADR session'}else{$evidence+=$lines[$lastMetadata].Trim()}
    if($lastCycle -ge 0){
        $prefix=[regex]::Match($lines[$lastCycle],'\[(\d\d/\d\d/\d{4})\s+(\d\d:\d\d:\d\d)')
        if(-not $prefix.Success){$issues+='Replication timestamp cannot be parsed'}else{
            $stamp=[datetime]::ParseExact(($prefix.Groups[1].Value+' '+$prefix.Groups[2].Value),'dd/MM/yyyy HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)
            $age=((Get-Date)-$stamp).TotalSeconds
            if($age -lt -60 -or $age -gt $MaxAgeSeconds){$issues+="Replication cycle not recent ($([int]$age) s)"}
            else{$evidence+=("{0} ({1} s old)" -f $lines[$lastCycle].Trim(),[int]$age)}
        }
        for($i=$lastCycle+1;$i -lt $lines.Count;$i++){ if($lines[$i] -match '\b(?:PADR\d+[ES]|ITADB\d+[ES]|PAREP\d+[ES])\b'){$issues+=('Product error after last cycle: '+$lines[$i].Trim());break} }
    }
    if($SafeName){
        $hit=@($lines | Where-Object { $_ -match 'PAREP0213I' -and $_.Contains('['+$SafeName+'(') -and $_ -match 'Replicated \[[1-9]' })
        if(-not $hit.Count){$issues+="no PAREP0213I replication record for Safe $SafeName"}else{$evidence+=$hit[-1].Trim()}
    }
}
[pscustomobject]@{Passed=($issues.Count -eq 0);Message=($issues -join ';');Evidence=$evidence}
