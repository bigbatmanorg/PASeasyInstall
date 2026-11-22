# Read-only check of Gpo-Task.ps1.
param([string]$Stage, [hashtable]$Settings)
$ErrorActionPreference = 'Stop'
if ($Stage -eq 'Prepare') {
    $rule = Get-NetFirewallRule -Name 'PASeasyInstall-Management' -ErrorAction SilentlyContinue
    $allowed = [bool]($rule -and $rule.Enabled -eq 'True' -and $rule.Action -eq 'Allow' -and
        ($rule | Get-NetFirewallPortFilter).LocalPort -contains [string][int]$Settings.ManagementPort)
    return [pscustomobject]@{
        Passed = $allowed
        Message = "Firewall rule for the management port $($Settings.ManagementPort): $allowed"
        Evidence = @("RuleEnabled=$allowed")
    }
}
if ($Stage -eq 'Member') {
    # The computer part of the resultant set of policy names the GPOs that were applied.
    $name = [string]$Settings.GpoName
    $report = (@(& gpresult.exe /scope computer /r 2>&1) | ForEach-Object { [string]$_ }) -join "`n"
    $applied = $report.Contains($name)
    return [pscustomobject]@{
        Passed = $applied
        Message = "Applied computer GPOs include '$name': $applied"
        Evidence = @("GpoApplied=$applied")
    }
}
Import-Module GroupPolicy -ErrorAction Stop
Import-Module ActiveDirectory -ErrorAction Stop
$domain = Get-ADDomain -ErrorAction Stop
$missing = @()
foreach ($entry in @($Settings.Roles)) {
    $part = ([string]$entry).Split('|')
    $gpoName = 'CyberArk Hardening - ' + $part[1]
    $unit = 'OU=' + $part[1] + ',OU=CyberArk,' + $domain.DistinguishedName
    $linked = @()
    try {
        $linked = @((Get-GPInheritance -Target $unit -ErrorAction Stop).GpoLinks | Where-Object { $_.DisplayName -eq $gpoName })
    } catch {
        $linked = @()
    }
    if (-not $linked.Count) {
        $missing += $gpoName
    }
}
$inUnits = @(Get-ADComputer -Filter * -SearchBase ('OU=CyberArk,' + $domain.DistinguishedName) -ErrorAction SilentlyContinue).Count
$wanted = @($Settings.Servers).Count
return [pscustomobject]@{
    Passed = (-not $missing.Count -and $inUnits -ge $wanted)
    Message = "GPO links missing: $($missing.Count); servers in the CyberArk organisational units: $inUnits of $wanted"
    Evidence = @("ServersInUnits=$inUnits")
}
