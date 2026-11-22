# Get started

Three things to have ready, then two ways to get PASeasyInstall.

1. **A controller.** A Windows computer with Windows PowerShell 5.1. PASeasyInstall runs here.
2. **Empty servers** the controller can reach: Windows Server 2022 for the Vault, PVWA, CPM and PSM, Linux for PSM
   for SSH. See [Requirements](requirements.md) and [Preparing servers](../servers/index.md).
3. **Your CyberArk media**: the PAM Self-Hosted download, your `license.xml` and the recovery public key.
   PASeasyInstall contains no CyberArk file.

## Install PASeasyInstall

=== "PowerShell Gallery"

    ```powershell
    Install-Module PASeasyInstall -Scope CurrentUser
    Start-PASeasyInstall
    ```

    One module with the commands and the window. It needs no other module. Details and what a fresh Windows
    Server needs before its first `Install-Module`: [PowerShell Gallery](gallery.md).

=== "Portable ZIP"

    Download `PASeasyInstall-<version>-portable.zip` from
    [Releases](https://github.com/bigbatmanorg/PASeasyInstall/releases), unblock it, extract it and double-click
    `Start-PASeasyInstall.cmd`. Nothing is installed and the controller needs no internet access.
    Details: [Portable ZIP](portable.md).

The module is not code-signed. With the default policy of Windows Server nothing more is needed. If PowerShell
refuses to load it, see [Execution policy](execution-policy.md).

## Then

<div class="grid cards" markdown>

-   **[Your first lab](first-lab.md)**

    From empty servers to a running lab, step by step.

-   **[The window](../gui/index.md)**

    Every screen with a picture.

-   **[Commands](../commands/index.md)**

    The same from the prompt, one command per step.

</div>

!!! tip "Try it without any server"
    `Start-PASeasyInstall -Backend Mock` opens the same window with a simulated installer. It contacts nothing
    and installs nothing, so you can click through every step first.
