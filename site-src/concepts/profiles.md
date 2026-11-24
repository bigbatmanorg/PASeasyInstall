# Lab and Secure profiles

Every configuration has a security profile.

- **Lab** is what a lab built from virtual machine templates needs, and the only profile that was tested
  (CyberArk 15.0 and 15.2). The window always uses it. From the prompt: `-SecurityProfile Lab`.
- **Secure** is a legacy surface of the commands, and still their default (`-SecurityProfile` left out). It
  uses none of the shortcuts below: WinRM certificates must be trusted and match the name, PVWA needs a
  certificate you provide, CPM checks the certificate chain of PVWA, SSH host keys must be known already, and
  PVWA is not set up to trust PTA. **It is not qualified: no lab was ever installed with it.** Pass
  `-SecurityProfile Lab`.

## The lab shortcuts

Each one is listed before you install: in the window under *Lab shortcuts in use*, from the prompt as a warning
that starts with `SECURITY DEVIATION` (`Test-PASLabConfiguration`, `Get-PASLabPlan`). The steps that apply one
say so in their event too.

| Shortcut | What it means | Why a lab needs it |
|---|---|---|
| `WinRM.SkipCACheck`, `WinRM.SkipCNCheck` | The WinRM certificate of a Windows server is not checked | Lab servers have a self-signed certificate whose name does not match the address |
| `Vault.AllowRDP` | Remote desktop to the hardened Vault, from the controller only | To look at the Vault server |
| A self-signed PVWA certificate | PVWA creates its own HTTPS certificate for its computer name | No certificate authority in a lab |
| `CPM.AllowPinnedLeafTrust` | CPM (and PSM, the gateway and PTA) trust exactly that PVWA certificate | Same |
| Hosts entries for the PVWA name | CPM and PSM get a hosts entry for the PVWA name when it does not resolve | CPM and PSM call PVWA by its name; a lab often has no DNS |
| SSH host key trusted on first use | The host key of a Linux server is accepted at the first connection and logged | No list of known keys in a lab |
| PVWA trusts PTA | With PTA in the lab, see below | PTA creates its own certificate |

With the Lab profile you may also give **one password for everything**: `-LabPassword`, for every server account
and every Vault password that is not passed otherwise.

## PVWA and PTA

PVWA calls PTA over HTTPS, under the host name PTA registered in the Vault: PTA's own host name, the one in its
certificate (`https://<that name>/api/...`), not the name in the lab configuration. When PTA and PVWA are
installed, a last step on the first PVWA server (Lab only):

- puts the self-signed certificate PTA presents into the trusted roots of that server (trusted on first use,
  logged with its subject and thumbprint);
- adds a hosts entry for every name in that certificate that does not lead to the PTA address;
- checks itself with a real HTTPS call to PTA under each of those names.

Without it, the lab check reports *PTA is registered in the Vault (x of y connected), but PVWA cannot reach it*.
With the Secure profile this step is not run: PTA then needs a certificate of a certificate authority, and its
name in DNS.

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
servers and install again. Which labs were installed this way is in the
[release notes](../release-notes.md).

## Other switches

A configuration file can carry more lab overrides, each listed as a deviation: `PVWA.ValidateTLS`,
`CPM.ValidatePVWA`, `WinRM.RequireHTTPS`, and `<Component>.ApplyHardening` for a single component (Vault, PVWA,
CPM, PSM, PSMP). Any override is refused with the Secure profile. They exist for special cases and were not
tested one by one.
