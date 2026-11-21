# Get started

Three things to have ready, and two ways to get PASeasyInstall.

1. **A controller:** a Windows machine with Windows PowerShell 5.1. This is where you run PASeasyInstall.
   Windows Server 2022 or Windows 10/11 both work.
2. **Target servers:** fresh Windows Server 2022 machines for the Vault, DR, PVWA, CPM and PSM, plus Ubuntu
   24.04 (or RHEL/Rocky 8/9) for PSMP. Each one must be reachable from the controller.
3. **Your CyberArk media:** the PAM Self-Hosted installers (for example the 15.0 bundle ZIP), your
   `license.xml` and the public recovery key `recpub.key`. PASeasyInstall never ships vendor media.

<div class="grid cards" markdown>

-   **[Requirements](requirements.md)**

    Controller, target servers, network ports, sizing and media in detail.

-   **[Portable ZIP](portable.md)**

    Unzip and run. No installation, no internet access needed on the controller.

-   **[PowerShell Gallery](gallery.md)**

    `Install-Module PASeasyInstall`: the commands and the desktop (`Start-PASeasyInstall`) in one module.

-   **[Your first lab](first-lab.md)**

    From empty servers to a running Vault, PVWA, CPM, PSM and PSMP, step by step.

</div>

!!! note "Execution policy"
    PASeasyInstall is not code-signed. On most machines nothing extra is needed. On machines that enforce
    `AllSigned`, see [Execution policy](execution-policy.md).
