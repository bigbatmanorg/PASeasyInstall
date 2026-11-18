# Snapshot strategy

Snapshots turn a 45-minute rebuild into a one-minute reset. Take them **between** runs, never while a stage is
running, and shut the servers down cleanly first.

| Snapshot | When | Use it to |
|---|---|---|
| `os-ready` | After cloning, naming, addressing and checking WinRM/SSH | Rebuild the lab from scratch with a different selection |
| `vault-ready` | After the Vault (or Vault + DR) run succeeded | Try component combinations without reinstalling the Vault |
| `lab-ready` | After the whole lab succeeded and the health check passes | Reset after experiments, training sessions or demos |

!!! warning "Roll back sets, not single servers"
    The Vault stores every component's registration, and the DR Vault mirrors the Primary. Roll back the Vault together
    with every server that registered to it after the snapshot, and always roll the Primary and DR back together.

**Start order after a reset:** Vault (and DR), then PVWA, then everything else. PVWA started before the Vault is up
needs an app-pool recycle. See [Troubleshooting](../troubleshooting/index.md).
