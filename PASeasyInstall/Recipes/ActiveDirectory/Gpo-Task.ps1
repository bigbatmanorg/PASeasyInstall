# The CyberArk hardening GPOs of a lab domain. Three stages, in this order:
#   Prepare runs on a joined server: allows the installer's own management port in the Windows firewall. The
#           vendor GPOs turn the firewall on; without this rule the installer could not reach the server again.
#   Domain  runs on the domain controller: imports the vendor's GPO backup of each server role, links it to an
#           organisational unit under "CyberArk" and moves the servers of that role there.
#   Member  runs on a joined server: refreshes its computer policy, so that the GPO applies now.
# The GPO backups are the ZIP files in the Hardening folder of the vendor packages ("In Domain").
[CmdletBinding()]
param([ValidateSet('Prepare', 'Domain', 'Member')][string]$Stage, [hashtable]$Settings)
$ErrorActionPreference = 'Stop'

if ($Stage -eq 'Prepare') {
    $port = [int]$Settings.ManagementPort
    if ($port -lt 1 -or $port -gt 65535) {
        throw 'The management port of this server is not known'
    }
    $ruleName = 'PASeasyInstall-Management'
    # The vendor GPOs do not allow local exceptions that name only a port (they are ignored on the domain
    # profile). A rule that names the program too stays in force, like the WinRM rule Windows ships.
    # WinRM listens through the HTTP driver of Windows, which is the program "System".
    $rule = Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($rule -and $rule.Enabled -eq 'True' -and
        ($rule | Get-NetFirewallPortFilter).LocalPort -contains [string]$port -and
        ($rule | Get-NetFirewallApplicationFilter).Program -eq 'System') {
        return [pscustomobject]@{Changed = $false; Message = "The firewall allows the management port $port already" }
    }
    if ($rule) {
        Remove-NetFirewallRule -Name $ruleName -ErrorAction Stop
    }
    $null = New-NetFirewallRule -Name $ruleName -DisplayName 'PASeasyInstall management (WinRM)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -Program 'System' -ErrorAction Stop
    return [pscustomobject]@{Changed = $true; Message = "Firewall rule added for the management port $port" }
}

if ($Stage -eq 'Member') {
    $output = @(& gpupdate.exe /target:computer /force /wait:600 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw ('gpupdate failed (' + $LASTEXITCODE + '): ' + (($output | ForEach-Object { [string]$_ }) -join ' '))
    }
    return [pscustomobject]@{Changed = $true; Message = 'Computer policy refreshed' }
}

Import-Module GroupPolicy -ErrorAction Stop
Import-Module ActiveDirectory -ErrorAction Stop
Import-Module DnsServer -ErrorAction Stop
$domain = Get-ADDomain -ErrorAction Stop
if ($domain.DNSRoot -ine [string]$Settings.Domain) {
    throw "This domain controller serves $($domain.DNSRoot), not $($Settings.Domain)"
}

function Get-OrganisationalUnit([string]$Name, [string]$Parent) {
    $path = 'OU=' + $Name + ',' + $Parent
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$path'" -ErrorAction Stop)) {
        New-ADOrganizationalUnit -Name $Name -Path $Parent -ProtectedFromAccidentalDeletion $false -ErrorAction Stop
    }
    return $path
}

$top = Get-OrganisationalUnit 'CyberArk' $domain.DistinguishedName
$done = @()
# One entry per role: "<key>|<title>|<path of the GPO backup ZIP on this server>".
$roles = @{}
foreach ($entry in @($Settings.Roles)) {
    $part = ([string]$entry).Split('|')
    $roles[$part[0]] = @{ Title = $part[1]; Archive = $part[2] }
}
foreach ($key in @($roles.Keys | Sort-Object)) {
    $role = $roles[$key]
    $gpoName = 'CyberArk Hardening - ' + $role.Title
    $work = Join-Path ([IO.Path]::GetDirectoryName($role.Archive)) ($key + '-backup')
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
    Expand-Archive -LiteralPath $role.Archive -DestinationPath $work -Force
    # A GPO backup is a folder named {GUID} that holds bkupInfo.xml; Import-GPO wants its parent folder.
    $info = @(Get-ChildItem -LiteralPath $work -Recurse -Filter bkupInfo.xml -Force)
    if ($info.Count -ne 1) {
        throw "Expected one GPO backup in $($role.Archive); found $($info.Count)"
    }
    $backupId = [guid]$info[0].Directory.Name
    $null = Import-GPO -BackupId $backupId -Path $info[0].Directory.Parent.FullName -TargetName $gpoName -CreateIfNeeded -ErrorAction Stop
    $unit = Get-OrganisationalUnit $role.Title $top
    $linked = @((Get-GPInheritance -Target $unit -ErrorAction Stop).GpoLinks | Where-Object { $_.DisplayName -eq $gpoName })
    if (-not $linked.Count) {
        $null = New-GPLink -Name $gpoName -Target $unit -LinkEnabled Yes -ErrorAction Stop
    }
    $roles[$key].Unit = $unit
    Remove-Item -LiteralPath $work -Recurse -Force
}
# One entry per server: "<IPv4 address>=<role key>". The server registered its name in the DNS zone of the
# domain when it joined; that record gives the computer account.
foreach ($entry in @($Settings.Servers)) {
    $address, $key = ([string]$entry).Split('=')
    $record = @(Get-DnsServerResourceRecord -ZoneName $domain.DNSRoot -RRType A -ErrorAction Stop |
            Where-Object { $_.RecordData.IPv4Address.ToString() -eq $address -and $_.HostName -notmatch '^(@|DomainDnsZones|ForestDnsZones)$' })
    if ($record.Count -ne 1) {
        throw "Expected one DNS record for $address in $($domain.DNSRoot); found $($record.Count)"
    }
    $computer = Get-ADComputer -Identity $record[0].HostName -ErrorAction Stop
    $unit = [string]$roles[$key].Unit
    if ($computer.DistinguishedName -ne ('CN=' + $computer.Name + ',' + $unit)) {
        Move-ADObject -Identity $computer.DistinguishedName -TargetPath $unit -ErrorAction Stop
    }
    $done += ($computer.Name + ' -> ' + $roles[$key].Title)
}
return [pscustomobject]@{Changed = $true; Message = ('CyberArk hardening GPOs imported and linked: ' + ($done -join '; ')) }
