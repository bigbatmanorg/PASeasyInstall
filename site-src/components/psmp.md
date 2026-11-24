# PSM for SSH (PSMP)

Installs PSM for SSH on a Linux server and registers it with the Vault.

```powershell
Install-PASPSMP -ComputerName 192.0.2.41 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArk -SecurityProfile Lab -AcceptEula -Wait
```

In a lab configuration: `@{ Type = 'PSMP'; Name = 'psmp01'; Address = '192.0.2.41' }`, with `-AcceptEula`. In the
window: the line **PSMP (SSH sessions)** on the Lab step.

## What it needs

- **A Linux server:** Ubuntu 22.04 or 24.04, or RHEL or Rocky 8 or 9. Tested on Ubuntu 24.04 and once on Rocky
  Linux 9.
- **root.** The installation writes system packages and services, so it signs in as root; another account is
  refused. root must be able to sign in over SSH with its password once. The installer then creates its own SSH
  key on the controller, authorises it on the server and uses only the key. See
  [Server prerequisites](../servers/prerequisites.md#linux-servers).
- **The PSMP package for the distribution of the server.** The big ZIP holds one per distribution. The media
  step picks one; when the run can sign in it reads the distribution of the server and takes the matching
  package from the same folder or ZIP.
- The password of the Vault user Administrator, to register.
- **`-AcceptEula`** (window: the license box on the Servers step). It confirms that you read and accept the CyberArk
  end user license agreement of the installer. Without it the configuration is not valid.

## Steps

| Step | What it does |
|---|---|
| `media-upload` | Copies the PSMP package, verified by its SHA-256 |
| `preflight` | Distribution and version, the package manager |
| `prepare-tools` | Installs `unzip` from the distribution's repositories when it is missing |
| `extract`, `prerequisites` | Unpacks the installer and checks the prerequisites |
| `install` | Installs the package. On the RHEL family the package must be signed with CyberArk's key |
| `harden` | RHEL family: checks that the vendor's hardening, which runs inside the package installation, was applied. Ubuntu 24.04: the vendor's hardening does not apply there; a baseline of this installer is applied and checked instead |
| `register` | Creates the Vault environment of this PSMP. Waits for the Vault, the first PVWA and every CPM |
| `verify` | The PSMP service is active |

Before the first step the controller creates its SSH key and authorises it on the server with the root password
(*Setting up the SSH key*), and picks the PSMP package for the distribution it finds (*Choosing the installer
package*).

## After the installation

Connect through PSMP with the usual syntax:

```text
ssh <vault user>@<target account>@<target address>@<psmp address>
```

Depending on the platform PSMP asks for a reason before it opens the session.

## Good to know

- **A rebuilt server with the same name** registers again: the vendor setup recreates the credential files of
  the existing Vault users of that server. Two PSMP servers must not have the same host name.
- **Ubuntu cloud images:** packages that are installed already are never upgraded by the installation; system
  updates stay your decision.
- **Session recordings:** see [PSM](psm.md#good-to-know).
- An [HTML5 Gateway](html5gw.md) can share this server.
