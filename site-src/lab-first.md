# Made for labs

PASeasyInstall exists to make **CyberArk PAM labs** quick and repeatable. Building a lab by hand takes a day or
more of installers, prerequisites, registration and hardening. PASeasyInstall turns that into a plan you review
and one button.

## What it is for

- **Learning and certification practice.** Build a complete lab as often as you like, the same way every time.
- **Demos and proofs of concept.** A known, documented environment.
- **Testing.** Try upgrades, integrations, connectors, platforms and automation against a lab before you touch
  anything that matters.

## What it is not

- **Not a CyberArk product.** It is a community project, not reviewed, certified or supported by CyberArk. It
  drives the vendor's own installers, registration tools and hardening scripts; it does not replace them.
- **Not tested for production.** Everything was tested with the **Lab** security profile. The Secure profile,
  which keeps the vendor's security defaults and uses none of the lab shortcuts, exists in the commands but has
  never been run.
- **No media.** You supply your own licensed CyberArk download, license file and keys. No CyberArk file is part
  of this project.

!!! danger "Production use is at your own risk"
    PASeasyInstall comes under the MIT license **without warranty of any kind**. If you use it on systems that
    matter, you are responsible for checking the result against CyberArk's documentation, your own security
    requirements and your support agreements.

## The lab shortcuts

The Lab profile relaxes a few things on purpose, because a lab built from virtual machine templates needs them:
self-signed certificates, trusting an SSH host key on first use, remote desktop to the Vault from the controller.
Each one is listed before you install, as "Lab shortcuts in use" in the window and as `SECURITY DEVIATION` in the
plan. They are explained in [Lab and Secure profiles](concepts/profiles.md).

## Trademarks

CyberArk and the names of CyberArk products are trademarks of CyberArk Software Ltd. They are used here only to
describe what this tool installs.
