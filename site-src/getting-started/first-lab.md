# Your first lab

This walkthrough builds the lab PASeasyInstall was developed and exercised against: a **Primary + DR** Vault pair,
**PVWA**, **CPM**, **PSM** and **PSMP**, each on its own server. The example addresses below are placeholders;
use your own.

| Server | Example hostname | Example address | OS |
|---|---|---|---|
| Controller | CONTROLLER01 | 10.10.0.10 | Windows Server 2022 |
| Primary Vault | PAS-VAULT | 10.10.0.11 | Windows Server 2022 |
| DR Vault | PAS-DR | 10.10.0.12 | Windows Server 2022 |
| PVWA | PAS-PVWA | 10.10.0.21 | Windows Server 2022 |
| CPM | PAS-CPM | 10.10.0.22 | Windows Server 2022 |
| PSM | PAS-PSM | 10.10.0.23 | Windows Server 2022 |
| PSMP | PAS-PSMP | 10.10.0.31 | Ubuntu 24.04 |

## 1. Prepare the servers

Install Windows Server 2022 on the Windows servers with WinRM over HTTPS enabled, and Ubuntu 24.04 on the PSMP
server. Give each one a unique hostname and a static address. See [Server prerequisites](../servers/prerequisites.md).

On the PSMP server, install `unzip` and allow root password login once (or authorise the controller key yourself):

```bash
sudo apt-get update && sudo apt-get install -y unzip
```

## 2. Put the media on the controller

Copy the CyberArk bundle ZIP (or the single component ZIPs), `license.xml`, `recpub.key` and the VC++
redistributables into one folder, for example `C:\CyberArk\media`.

## 3. Open the desktop and fill in the six steps

=== "Portable ZIP"

    Extract the ZIP and double-click `Start-PASeasyInstall.cmd`.

=== "PowerShell Gallery"

    ```powershell
    Install-Module PASeasyInstall -Scope CurrentUser
    Start-PASeasyInstall
    ```

1. **Project & media:** name `Lab01`; add `C:\CyberArk\media`. All components show green chips.
2. **What to install:** *Primary + DR Vault*; one each of PVWA, CPM, PSM and PSMP; accept the PSMP EULA;
   *Servers in parallel*.
3. **Servers:** check the controller address (`10.10.0.10`); enter the Vault, DR and component addresses.
4. **Credentials:** keep `Administrator` / `root`; tick **Lab mode** and enter one password.
5. **Review plan:** six servers. The Lab-mode deviations are listed. There must be no issues.
6. **Install.**

## 4. Watch it run

The Vault installs first (about 10 minutes, including hardening and a reboot), then the DR Vault, then PVWA, and then CPM,
PSM and PSMP in parallel. PSM reboots several times; that is expected. A full lab typically completes in 40–60
minutes, depending on your hardware.

<!-- TODO(parent): replace the timing with measured numbers from the test campaign. -->

## 5. Check the result

```powershell
$h = Test-PASEnvironmentHealth -Config .\PASeasyInstall-Lab01.json -VaultCredential (Get-Credential Administrator)
$h.Healthy
$h.Components | Format-Table Component,User,Address,LoggedOn,Version
```

Then sign in to PVWA at `https://PAS-PVWA/PasswordVault` as `Administrator`. In Lab mode the PVWA uses a
self-signed certificate, so accept it in the browser or import it.
