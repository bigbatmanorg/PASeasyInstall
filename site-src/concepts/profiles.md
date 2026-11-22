# Lab and Secure profiles

Every configuration has a security profile.

- **Secure** is the default of the commands. It uses none of the shortcuts below: WinRM certificates must be
  trusted and match the name, PVWA needs a certificate you provide, CPM checks the certificate chain of PVWA,
  SSH host keys must be known already. **It has never been run.**
- **Lab** is what a lab built from virtual machine templates needs, and what everything was tested with. The
  window always uses it. From the prompt: `-SecurityProfile Lab`.

## The lab shortcuts

Each one is listed before you install: in the window under *Lab shortcuts in use*, from the prompt as a warning
that starts with `SECURITY DEVIATION` (`Test-PASLabConfiguration`, `Get-PASLabPlan`).

| Shortcut | What it means | Why a lab needs it |
|---|---|---|
| `WinRM.SkipCACheck`, `WinRM.SkipCNCheck` | The WinRM certificate of a Windows server is not checked | Lab servers have a self-signed certificate whose name does not match the address |
| `Vault.AllowRDP` | Remote desktop to the hardened Vault, from the controller only | To look at the Vault server |
| A self-signed PVWA certificate | PVWA creates its own HTTPS certificate for its computer name | No certificate authority in a lab |
| `CPM.AllowPinnedLeafTrust` | CPM (and the gateway and PTA) trust exactly that PVWA certificate | Same |
| SSH host key trusted on first use | The host key of a Linux server is accepted at the first connection and logged | No list of known keys in a lab |
| PVWA trusts the certificate PTA presents | With PTA in the lab | PTA creates its own certificate |

With the Lab profile you may also give **one password for everything**: `-LabPassword`, for every server account
and every Vault password that is not passed otherwise.

## Installing without hardening

Sometimes a test needs servers without the security settings. Then:

- **Window:** on the Servers step, switch **Advanced** on and *Apply the vendor hardening* off.
- **Prompt:** `New-PASLabConfiguration ... -SecurityProfile Lab -SkipHardening`.

Everything is installed and registered. What is left out:

- the vendor hardening of the Vault and DR Vault servers (firewall, services);
- the vendor hardening of PVWA, CPM, PSM and PSM for SSH;
- the CyberArk hardening GPOs of a new domain.

It is listed as `SECURITY DEVIATION: <Component>.ApplyHardening = False` for each component, and the window says
**The servers will NOT be hardened** on the Install step and in the question before the installation.

It is possible only with the Lab profile, and it is for tests only. To get a hardened lab afterwards, reset the
servers and install again.

!!! note "State"
    Installing without hardening is new. Whether every component was installed this way in the test lab is in
    the [release notes](../release-notes.md) and in
    [STATUS.md](https://github.com/bigbatmanorg/PASeasyInstall/blob/main/Docs/STATUS.md).

## Other switches

A configuration file can carry more lab overrides, each listed as a deviation: `PVWA.ValidateTLS`,
`CPM.ValidatePVWA`, `WinRM.RequireHTTPS`, and `<Component>.ApplyHardening` for a single component. They exist for
special cases and were not tested one by one.
