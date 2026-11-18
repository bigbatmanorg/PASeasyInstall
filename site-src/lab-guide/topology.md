# Topology and sizing

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

All servers on: about **24–30 GB RAM** for the targets. That is fine for a lab and below CyberArk's production
recommendations.

## Smaller hosts

- **Co-locate PVWA and CPM** on one server (same address on [step 3](../gui/servers.md)).
- **Run what you test.** Components keep working when you stop servers you don't need right now. Keep the **DR Vault
  running** whenever components are active, because password rotation waits for DR replication.
- **Thin-provisioned disks** keep the real storage use small: a fresh lab uses a few GB per server.

## Network

Put the targets on a private lab network. Give every server a **static** address, and make sure the controller can
reach WinRM HTTPS (5986) on Windows targets and SSH (22) on PSMP. A hosts-file entry (or lab DNS) for every server
name keeps certificates and URLs readable, for example `https://PAS-PVWA/PasswordVault`.
