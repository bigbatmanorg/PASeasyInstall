# PSMP

Installs **PSM for SSH** on Linux: Ubuntu 22.04/24.04 or RHEL/Rocky 8/9. The lab reference is Ubuntu 24.04.

| Stage | What it does |
|---|---|
| `management` | Authorises the controller's SSH key, from the password you type once |
| `media-upload` | Copies the PSMP package for the target's distribution, SHA-256 verified |
| `preflight` | OS identity and version, `unzip`, and the package manager |
| `extract`, `prerequisites` | Extracts the installer and checks the prerequisites |
| `install` | Installs `CARKpsmp`. Requires **`acceptEula`**, which is set by the checkbox on [step 2](../gui/what-to-install.md). |
| `register` | Registers PSMP in the Vault |
| `harden` | Baseline verification. On Ubuntu, the vendor's RHEL hardening does not apply. |
| `verify` | `psmpsrv` is active |

The media step selects one PSMP package. Once it can sign in, the run reads the server's `/etc/os-release` and uses
the package for that distribution (Ubuntu 22/24, RHEL-family 8/9 including Rocky and AlmaLinux, SLES 15) from the same
bundle or folder. On RHEL-family servers the RPM must be signed by CyberArk's published key.

Connect through PSMP with the standard syntax: `ssh <vault-user>@<target-account>@<target-address>@<psmp-address>`.

Depending on the platform's policy, PSMP asks for a reason for the connection before it opens the session.

!!! note "Session recordings"
    The Vault creates the `PSMRecordings` safe when the first session is recorded, not during installation.
    Only members of the Vault **Auditors** group can see it, so the built-in `Administrator` gets "not found" from
    the recordings pages and API. Review recordings as the built-in `Auditor` user, or add your reviewer to Auditors.

!!! note "Ubuntu cloud images"
    Preflight installs `unzip` from the OS repositories when it is missing. Package installs never upgrade
    packages that are already installed, and Ubuntu's `needrestart` is told not to restart PASeasyInstall's
    stages; OS updates stay your decision.

!!! note "Rebuilt PSMP server"
    Installing PSMP again on a rebuilt server with the same name re-registers it: the vendor setup recreates the
    credential files of that server's existing Vault users.
