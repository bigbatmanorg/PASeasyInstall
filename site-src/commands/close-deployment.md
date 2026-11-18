# Close-PASDeployment

Closes an **unresolved deployment record** so its environment, and the servers it claimed, can be deployed again.
It records a decision you made. **It never contacts or changes a server.**

```powershell
Close-PASDeployment -RunId <32-character id> -Reason <text> [-Force]
```

Use it when a deployment ended **Unknown** or **Interrupted**, or failed while holding a claim, and you have decided
what to do with its servers. Typically you reset them to a clean state and want to install again. Until the record
is closed, a new deployment of the same environment stops with:

```text
Environment 'LabB' has unresolved deployment 83cf015f78bd4743a54e6d0a9d0dd301. Resume or reconcile it before creating another.
Unreconciled resource 'host-192.0.2.11'; resume its owning run before starting another deployment
```

What it does:

- marks each unresolved run of the deployment **Abandoned**, with your reason, and writes a `RunAbandoned` event to
  its journal;
- releases the controller claims (`C:\ProgramData\PASeasyInstall-Coordination`) owned by those runs, and no others;
- refuses while a controller of the deployment is still running.

It asks for confirmation; `-Force` skips the question (scripts).

```powershell
Close-PASDeployment -RunId 83cf015f78bd4743a54e6d0a9d0dd301 -Reason 'Vault server reset to its clean state'
```

```text
RunId          : 83cf015f78bd4743a54e6d0a9d0dd301
AbandonedRuns  : {83cf015f78bd4743a54e6d0a9d0dd301}
ReleasedClaims : 3
Note           : No server was changed. Reset servers that may hold a partial installation before deploying again.
```

!!! warning "Servers are not cleaned up"
    A server touched by the abandoned run may hold a partial installation. Reset it before installing again. A Linux
    server also keeps its own lock in `~/.paeasyinstall/locks` until it is reset or that lock is removed.

If the outcome is not yet known, prefer [Resume-PASeasyDeployment](resume.md): it reconciles the recorded attempt and
continues without repeating work.
