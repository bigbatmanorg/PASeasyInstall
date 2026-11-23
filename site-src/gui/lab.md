# Step 2: Lab

Choose your lab topology and component counts directly. **There are no Starter, Standard, Full or
other deployment workflow presets.**

## Vault topology

Select **New Vault** (one Primary) or **New Vault with DR** (Primary + Disaster Recovery). Both
choices use fresh, disposable lab servers. The **Advanced** toggle also makes **Use existing Vault**
available for experienced lab operators; the normal path is a new Primary.

## Component counts

Use `+` and `−` to select how many PVWA, CPM, PSM, PSM for SSH (PSMP), HTML5 Gateway
and PTA instances to install. Zero leaves that component out. The normal limit is two per component;
Advanced raises the limit to four. Your Vault license and the available media can impose lower limits.

- A gateway requires a PVWA; it may share a PSMP server, or use its own Linux server.
- PTA requires a PVWA and a suitable RHEL-family server.
- PVWA and CPM can share a Windows server, or use separate servers.

There is a single path through the wizard: **Media → Lab → Servers → Install**.
The media and component selection decide the resulting server topology automatically. No special
workflow selector or CLI command entry is required.

The earlier screenshots of preset cards do not represent this version; new screenshots will be
collected during the S01 real-WPF lab validation.

## Server for CPM

In every lab, *Install CPM on the PVWA server (one server less)* is switched on. Switch it off to give CPM a
server of its own; the Servers step then has one more line. A CPM on its own server is installed at the same
time as PVWA.

## Server for the HTML5 Gateway

In a lab with PSM for SSH and an HTML5 Gateway, *Install the HTML5 Gateway on the PSM for SSH server (one server
less)* is switched on. Switch it off to give the gateway a Linux server of its own; the Servers step then has
one more line.

## Active Directory (Advanced only)

- **No domain**: the servers stay as they are.
- **New domain**: one more server becomes the domain controller of a new forest. The PVWA, CPM and PSM servers
  join it before they are installed (they restart once), and at the end the CyberArk hardening GPOs from the
  vendor packages are imported and applied to them. Enter the DNS name of the domain, for example `pam.lab`.
- **A domain I already have**: the PVWA, CPM and PSM servers join it. Nothing in that domain is changed, and its
  GPOs are not touched. On the Servers step you enter the address of one of its DNS servers and a domain account
  that may join computers.

Vault servers are never joined to a domain. More: [Active Directory](../components/ad.md).

## Name of the lab

Installations are listed under this name. Letters, digits, dot, dash and underscore.

Next: [Step 3: Servers](servers.md).
