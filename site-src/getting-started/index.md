# Get started

PASeasyInstall builds a CyberArk PAM Self-Hosted **lab** on servers you provide. You run it on one Windows
computer, the *controller*, either in its window or with PowerShell commands. It is a community project, not
affiliated with CyberArk.

Have three things ready:

1. **A controller.** A Windows computer with Windows PowerShell 5.1. PASeasyInstall runs here and reaches every
   server over the network.
2. **Freshly installed servers** the controller can reach: Windows Server 2022 for the Vault, PVWA, CPM and PSM;
   Linux for PSM for SSH, the HTML5 Gateway and PTA. See [Requirements](requirements.md) and
   [Preparing servers](../servers/index.md).
3. **Your own CyberArk media**: the PAM Self-Hosted download, your `license.xml` and the recovery public key
   (`recpub.key`). PASeasyInstall contains no CyberArk file and no license.

## Get PASeasyInstall

=== "PowerShell Gallery"

    ```powershell
    Install-Module PASeasyInstall -Scope CurrentUser
    Start-PASeasyInstall
    ```

    One module with all commands and the window. It needs no other module. What a fresh Windows Server needs
    before its first `Install-Module`: [PowerShell Gallery](gallery.md).

=== "Portable ZIP"

    Download `PASeasyInstall-<version>-portable.zip` from
    [Releases](https://github.com/bigbatmanorg/PASeasyInstall/releases), unblock it, extract it and double-click
    `Start-PASeasyInstall.cmd`. Nothing is installed on the controller, and it needs no internet access.
    Details: [Portable ZIP](portable.md).

The module is not code-signed. With the default execution policy of Windows Server nothing more is needed. If
PowerShell refuses to load it, see [Execution policy](execution-policy.md).

## Then

<div class="grid cards" markdown>

-   **[Your first lab](first-lab.md)**

    From empty servers to a checked lab, step by step.

-   **[The window](../gui/index.md)**

    Every screen of the window.

-   **[Commands](../commands/index.md)**

    The same from the PowerShell prompt.

</div>

!!! tip "Try it without any server"
    `Start-PASeasyInstall -Backend Mock` opens the same window with a simulated installation. It contacts no
    server and installs nothing, so you can click through every step first. The window shows **Simulation** in
    its top bar while it runs this way.
