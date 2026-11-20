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
    Install-Module PASeasyInstall, PASeasyInstall.UI -Scope CurrentUser
    Start-PASeasyInstall
    ```

1. **Project & media:** name `Lab01`; add `C:\CyberArk\media`. All components show green chips.
2. **What to install:** *Primary + DR Vault*; one each of PVWA, CPM, PSM and PSMP; accept the PSMP EULA.
3. **Servers:** check the controller address (`10.10.0.10`); enter the Vault, DR and component addresses.
4. **Credentials:** keep `Administrator` / `root`; tick **Lab mode** and enter one password.
5. **Review plan:** six servers. The Lab-mode deviations are listed. There must be no issues.
6. **Install.**

## 4. Watch it run

The Vault installs first, then the DR Vault, then PVWA, CPM, PSM and PSMP, one after the other. PSM reboots several
times; that is expected. The run id is shown above the progress cards. Times measured in the 1.0 test labs (PAM 15.0
and 15.2, 2–4 vCPU servers); 2.0.0 has not been timed yet:

| Step | Time |
|---|---|
| Vault alone | about 7 minutes |
| Vault + DR pair | about 17 minutes |
| PVWA | about 8 minutes |
| CPM | about 4 minutes |
| PSM (several reboots) | 13–15 minutes |
| PSMP | 3–6 minutes |

A full lab (Vault + DR, PVWA, CPM, PSM, PSMP) takes about an hour plus media upload.

## 5. Check the result

```powershell
$h = Test-PASHealth -Path .\PASeasyInstall-Lab01.json -VaultCredential (Get-Credential Administrator)
$h.Healthy
$h.Components | Format-Table Component,User,Address,LoggedOn,Version
```

Then sign in to PVWA at `https://PAS-PVWA/PasswordVault` as `Administrator`. In Lab mode the PVWA uses a
self-signed certificate, so accept it in the browser or import it.

## The same lab from the prompt

```powershell
$media = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path C:\CyberArk\media)
$cfg = New-PASLabConfiguration -Environment Lab01 -VaultMode PrimaryDR `
        -PrimaryAddress 10.10.0.11 -DRAddress 10.10.0.12 -ControllerAddress 10.10.0.10 `
        -Instances @(@{ Type = 'PVWA'; Name = 'PAS-PVWA'; Address = '10.10.0.21' },
                     @{ Type = 'CPM';  Name = 'PAS-CPM';  Address = '10.10.0.22' },
                     @{ Type = 'PSM';  Name = 'PAS-PSM';  Address = '10.10.0.23' },
                     @{ Type = 'PSMP'; Name = 'PAS-PSMP'; Address = '10.10.0.31' }) `
        -Media $media -SecurityProfile Lab -AcceptEula
Export-PASLabConfiguration -Configuration $cfg -Path .\Lab01.json
Install-PASLab -Path .\Lab01.json -Wait
```

If a step fails, see [Troubleshooting](../troubleshooting/index.md).
