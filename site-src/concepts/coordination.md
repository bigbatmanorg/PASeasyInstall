# Coordination and locks

Several deployments can run from one controller, as long as each uses its own environment name. Three mechanisms keep
them from colliding:

| Mechanism | Where | Prevents |
|---|---|---|
| **Environment claim** | `C:\ProgramData\PASeasyInstall-Coordination\*.json` on the controller | Two runs of the same environment at once |
| **Target lock** | On each target: the toolkit's lock folder (Windows) or `~/.paeasyinstall/locks/<host>` (Linux) | Two runs changing the same server |
| **Vault gate** | On the controller, per Vault | Two authenticated Vault operations (registrations, PACLI sessions) colliding |

Claims and locks are released when a run **completes**. A run that **fails** keeps them on purpose: its state on the
targets has not been reconciled yet. A new run with the same environment name is refused with:

```text
Unreconciled resource 'environment-Lab01'; resume its owning run before starting another deployment
```

and a new run against a locked server with:

```text
PAExecLocked: target 'psmp01' is locked by another run (locked:<runId>); inspect before any takeover
```

**What to do:** resume the owning run (`Resume-PASeasyDeployment`). Or, if the failed run provably dispatched nothing
to the server (for example it failed during validation), remove only that run's claims and locks. See
[Troubleshooting](../troubleshooting/index.md).

<!-- TODO(parent): link the stale-lock command once it exists (release plan item 4). -->
