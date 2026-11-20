# Components

Each component is installed by a **recipe**: an ordered list of stages. Every stage runs as a recorded attempt
on the target and is verified before the next one starts. `Get-PASStageCatalog -Component <name>` lists the stages,
and the desktop shows them as chips on [step 6](../gui/install.md).

<div class="grid cards" markdown>

-   **[Vault](vault.md)**: the Primary Vault server, keys, configuration and hardening.
-   **[DR Vault](dr.md)**: a standby Vault replicated from a new Primary.
-   **[PVWA](pvwa.md)**: web access, TLS, registration and hardening.
-   **[CPM](cpm.md)**: password management, registration and hardening.
-   **[PSM](psm.md)**: session isolation and recording, with the vendor's reboots handled.
-   **[PSMP](psmp.md)**: PSM for SSH on Linux.
-   **[Active Directory](ad.md)**: a new forest and domain controller for domain-joined scenarios.

</div>

Typical durations in the reference lab (2 vCPU / 4 GB targets): Vault 8 minutes, Primary + DR 17 minutes, PVWA 10,
CPM 3–4, PSM 15 (with three vendor reboots), PSMP 2, and AD 5.

!!! info "PTA"
    Privileged Threat Analytics (PTA) is not included.
