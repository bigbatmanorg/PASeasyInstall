# Active Directory

Creates a **new Active Directory forest** with DNS on a dedicated Windows Server. Use it for lab scenarios that need
domain accounts or domain-joined component servers. AD is available from the command line in this release, not
from the desktop.

| Stage | What it does |
|---|---|
| `ad-prerequisites` | AD DS and DNS roles |
| `ad-install` | Promotes the server to the first domain controller of the new forest (detached, survives the reboot) |
| `ad-reboot` | A one-time SYSTEM task continues after the promotion reboot; no autologon |
| `ad-verify` | `dcdiag` basics, the domain's DNS SRV records, the domain SID and the AD services |

Defaults: domain `pam.lab`, NetBIOS name `PAM`. The DNS server has no forwarders; add them if the lab needs
internet name resolution.

!!! warning "Never join Vault servers to the domain"
    Vault and DR servers must stay out of the domain. That is a CyberArk requirement, and PASeasyInstall refuses it.
