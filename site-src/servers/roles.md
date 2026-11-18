# Roles and sizing

## Reference lab

| Server | vCPU | RAM | Disk | Notes |
|---|---|---|---|---|
| Controller | 2 | 8 GB | 100 GB | Windows; runs the desktop and keeps the media cache |
| Primary Vault | 2 | 4 GB | 100 GB | not domain-joined |
| DR Vault | 2 | 4 GB | 100 GB | not domain-joined |
| PVWA | 2 | 4 GB | 100 GB | |
| CPM | 2 | 4 GB | 100 GB | can share a server with PVWA (6 GB then) |
| PSM | 2 | 4 GB | 100 GB | 8 GB is more comfortable for sessions |
| PSMP | 2 | 2–4 GB | 40 GB | Ubuntu 24.04 |
| Domain controller (optional) | 2 | 2–4 GB | 60 GB | |

These sizes are what PASeasyInstall was exercised with. They are fine for a lab and below CyberArk's production
recommendations.

## Smaller labs

- **Co-locate PVWA and CPM** on one server: give both the same address on [step 3](../gui/servers.md).
- **Install only what you need.** Every component is optional except the Vault.
- **Keep the DR Vault running** whenever components are active. With a DR Vault configured, the Vault rotates
  component passwords only after DR has replicated them.

## Network

Put the servers on a private lab network. Give every server a **static** address, and make sure the controller can
reach WinRM HTTPS (5986) on Windows servers and SSH (22) on PSMP. A hosts-file entry (or lab DNS) for every server
name keeps certificates and URLs readable, for example `https://PAS-PVWA/PasswordVault`. The full port list is in
[Requirements](../getting-started/requirements.md#network).
