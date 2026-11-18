param([string]$Stage,[hashtable]$Settings)
$domain=[string]$Settings.Domain
$cs=Get-CimInstance Win32_ComputerSystem
$isDC=($cs.DomainRole -in @(4,5) -and $cs.Domain -ieq $domain)
if($Stage -eq 'Preflight'){
    $check=(Get-Command Test-ADDSForestInstallation -ErrorAction SilentlyContinue)
    return [pscustomobject]@{Passed=[bool]$check;Message='AD DS feature and deployment tools present'}
}
if($Stage -eq 'Install'){
    # Promotion completion is recorded before reboot; do not demand active AD services yet.
    $marker=Join-Path ([string]$Settings.StageRoot) 'forest-promotion.done'
    if(Test-Path -LiteralPath $marker){
        try {
            $promotion=Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json -ErrorAction Stop
            $valid=($promotion.schemaVersion -eq 2 -and $promotion.domain -ieq $domain -and $promotion.attemptId -match '^[a-f0-9]{32}$' -and $promotion.bootUtc)
        }catch{$valid=$false}
        return [pscustomobject]@{Passed=[bool]$valid;Message='Structured AD promotion checkpoint; reboot and independent health checks pending'}
    }
    return [pscustomobject]@{Passed=$isDC;Message='Matching domain controller already present; no new forest promotion checkpoint'}
}
$ntds=Get-Service -Name NTDS -ErrorAction SilentlyContinue
$dns=Get-Service -Name DNS -ErrorAction SilentlyContinue
$sysvol=Test-Path (Join-Path $env:SystemRoot 'SYSVOL\sysvol')
return [pscustomobject]@{Passed=($isDC -and $ntds -and $dns -and $ntds.Status -eq 'Running' -and $dns.Status -eq 'Running' -and $sysvol);
    Message='AD domain, NTDS, DNS and SYSVOL verification';Evidence=@("Domain=$($cs.Domain)","SYSVOL=$sysvol")}
