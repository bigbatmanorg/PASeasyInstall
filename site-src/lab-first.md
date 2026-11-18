# Lab first

PASeasyInstall exists to make **CyberArk PAM labs** quick and repeatable. Building a lab by hand typically takes a
day or more of installers, prerequisites, registration and hardening. PASeasyInstall turns that into a reviewed plan
and a single click.

## What we promote

- **Labs for learning and certification practice.** Build a full Vault + DR + PVWA + CPM + PSM + PSMP environment
  as often as you like, with the same reviewed plan every time.
- **Demos and proof-of-concepts.** A consistent, documented environment every time.
- **Testing.** Try upgrades, integrations, connectors, platforms and automation against a lab before touching anything
  that matters.

## Production is your responsibility

You can point PASeasyInstall at any server you can reach. It uses the vendor's own installers and hardening, and its
**Secure** profile keeps the vendor's security defaults. Even so:

!!! danger "Production use is at your own risk"
    PASeasyInstall is provided under the MIT license **without warranty of any kind**. It is not a CyberArk product,
    and it is not reviewed, certified or supported by CyberArk. If you use it on systems that matter, you are
    responsible for validating the result against CyberArk's documentation, your own security requirements and your
    support agreements.

**Lab mode** in particular uses deliberate, audited shortcuts that are fine for a lab and wrong for production: one
universal password, self-signed certificates, and trusting a host key on first use. They are listed on the
[Review plan](gui/review.md) step and explained in [Lab and Secure profiles](concepts/profiles.md).

## Trademarks

CyberArk and the names of CyberArk products are trademarks of CyberArk Software Ltd. They are used here only to
describe what this tool installs. You need your own licensed CyberArk installation media and license file.
