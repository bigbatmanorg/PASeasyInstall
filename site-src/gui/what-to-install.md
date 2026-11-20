# 2 What to install

![Step 2: Vault option, components and license agreement](../assets/screenshots/2-what-to-install.png)

## Vault

| Option | What happens |
|---|---|
| **Primary Vault** | One new Vault server. |
| **Primary + DR Vault** | A new Primary and a standby DR Vault, installed together and replicated from day one. Replication is verified with a test Safe. |
| **Existing Vault** | No Vault installation. The components register to a Vault that already runs. You enter its address on the next step. |

!!! note
    A DR Vault can only be added together with a **new** Primary. Attaching DR to an existing Primary is not supported.

## Components

Choose how many servers of each component to install: **PVWA**, **CPM**, **PSM** (Windows) and **PSMP** (Linux),
up to four each. The counts are preselected from the media you added. You name each server on the next step. Giving
two instances the same address installs them on one server (co-location, for example PVWA and CPM together).

## License agreement

When PSMP is selected, accept the CyberArk EULA here. The PSMP installer runs unattended and requires the acceptance
up front. The other installers include it in their silent setup.

## Installation order

Components are installed **one after the other**: the Vault (and DR) first, then PVWA, then CPM, PSM and PSMP. PVWA
comes first because its registration creates the Vault objects the other components register against. There is no
parallel mode in 2.0.

CPM waits for the PVWA whose certificate it trusts.
