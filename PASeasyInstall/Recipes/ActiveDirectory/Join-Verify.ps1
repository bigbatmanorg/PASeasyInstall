param([string]$Stage, [hashtable]$Settings)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Join-State.ps1')
$cs = Get-CimInstance Win32_ComputerSystem
$joined = ($cs.PartOfDomain -and $cs.Domain -ieq [string]$Settings.Domain)
if ($Stage -eq 'Check') {
    $records = @(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.' + [string]$Settings.Domain) -Type SRV -ErrorAction Stop | Where-Object { $_.Type -eq 'SRV' })
    return [pscustomobject]@{Passed = ($records.Count -gt 0); Message = 'Independent AD LDAP SRV DNS probe' }
}
if ($Stage -eq 'Join') {
    $pending = Test-PASeasyJoinPending $Settings
    return [pscustomobject]@{
        Passed = ($joined -or
            $pending)
        Message = 'Domain membership or protected same-boot successful Add-Computer submission'
        Evidence = @("PendingSameBoot=$pending")
    }
}
$secure = $false
$srv = @()
if ($joined -and $cs.DomainRole -notin @(4, 5)) {
    try {
        $secure = [bool](Test-ComputerSecureChannel -ErrorAction Stop)
        $srv = @(Resolve-DnsName -Name ('_ldap._tcp.dc._msdcs.' + [string]$Settings.Domain) -Type SRV -ErrorAction Stop | Where-Object { $_.Type -eq 'SRV' })
    } catch { $secure = $false }
}
return [pscustomobject]@{
    Passed = ($joined -and
        $secure -and
        $srv.Count -gt 0)
    Message = "Domain membership, machine secure channel and LDAP SRV: $($cs.Domain)"
    Evidence = @("SecureChannel=$secure", "LdapSrvCount=$($srv.Count)")
}
