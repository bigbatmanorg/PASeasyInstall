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

Connect through PSMP with the standard syntax: `ssh <vault-user>@<target-account>@<target-address>@<psmp-address>`.

!!! note "Ubuntu cloud images"
    Install `unzip` first (`apt-get install -y unzip`). Preflight stops with `unzip required` otherwise.
