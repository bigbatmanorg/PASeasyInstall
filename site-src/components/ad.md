# Active Directory

A lab can stay without a domain, get a **new domain**, or join **a domain you already have**. With a domain, the
Windows servers of PVWA, CPM and PSM are joined to it before they are installed. Vault servers are never joined;
PASeasyInstall refuses that.

## A new domain

```powershell
$cfg = New-PASLabConfiguration -Environment MyLab -VaultMode Primary -PrimaryAddress 192.0.2.11 `
    -ControllerAddress 192.0.2.10 -Media $media -SecurityProfile Lab `
    -DomainMode New -DomainName pam.lab -DomainControllerAddress 192.0.2.5 `
    -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21' },
                 @{ Type = 'CPM';  Name = 'CPM01';  Address = '192.0.2.21' },
                 @{ Type = 'PSM';  Name = 'PSM01';  Address = '192.0.2.31' })
```

In the window: **New domain** on the Lab step.

One more Windows Server 2022 becomes the first domain controller of a new forest. It needs a fixed address, and
nothing else is installed on it. Its local administrator becomes the administrator of the domain, with the same
password. You set one more password, for the Directory Services Restore Mode.

What the run does:

1. **The forest.** Steps `ad-prerequisites` (the AD DS and DNS roles; the server uses itself as DNS server),
   `ad-install` (promotion to domain controller), `ad-reboot`, `ad-verify`.
2. **The joins**, when the forest is there, each on its own server and at the same time: `dns` (the server uses
   the domain controller as DNS server), `join`, `reboot`, `local-admin` (the domain account of the lab becomes
   a local administrator of the server), `verify`.
3. **The components**, on the joined servers, as in a lab without a domain. The Vault is installed from the
   start, at the same time as the forest.
4. **The CyberArk hardening GPOs**, at the very end. The GPO backups that CyberArk ships inside the PVWA, CPM
   and PSM packages are imported into the new domain, linked, and applied to the joined servers.

Tested once from clean servers (CyberArk 15.2): forest, two joined servers, Vault, PVWA, CPM, PSM, GPOs; the lab
check was Healthy, also after a restart of the joined servers. Installed at the same time, such a lab with a PSM
for SSH took 20 minutes.

Only the forest, without a lab:

```powershell
Install-PASDomainController -ComputerName 192.0.2.5 -DomainName pam.lab -SecurityProfile Lab -Wait
```

## A domain you already have

```powershell
New-PASLabConfiguration ... -DomainMode Existing -DomainName corp.example `
    -DomainControllerAddress 192.0.2.5 -DomainUsername joinaccount
```

In the window: **A domain I already have**.

The servers use the DNS server at `-DomainControllerAddress` and join with a domain account that may join
computers. **Nothing in that domain is changed**: no GPO is imported or linked. Import the CyberArk hardening
GPOs there yourself if you want them.

Only the join itself was run this way (a server joined the lab's own domain as an existing one). A domain that
PASeasyInstall did not create was not tried.

## Good to know

- **The firewall of a joined server** is switched on by the GPOs. Before that the installer adds one rule for
  its own management connection ("PASeasyInstall management (WinRM)"). It stays after the installation.
- **A server with PSM and another component** gets no GPO: the vendor ships no GPO for that combination that is
  used here.
- **The vendor's local hardening still runs** on a joined server, next to the GPO. Where both set the same
  thing, the GPO wins.
- **PSM** is registered with its local users `PSMConnect` and `PSMAdminConnect`, also on a joined server.
- **Without hardening** (`-SkipHardening`) no GPO is imported.
- The DNS server of a new domain has no forwarders. Add them if the lab needs to resolve internet names.
