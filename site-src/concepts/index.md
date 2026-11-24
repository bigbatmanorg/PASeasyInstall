# How it works

<div class="grid cards" markdown>

-   **[The parts](architecture.md)**: the controller, the servers, and how work reaches them.
-   **[Servers at the same time](parallel.md)**: what runs side by side, what waits, and in which order the
    components register (PVWA, CPM, PSM and PSM for SSH, PTA last).
-   **[Runs and resume](durable-runs.md)**: why an installation survives a closed window or a restart, and why
    nothing is repeated blindly.
-   **[Locks](coordination.md)**: what protects a half-installed server and the Vault, and how to release it.
-   **[Security](security.md)**: where passwords live and what never touches a disk.
-   **[Lab and Secure profiles](profiles.md)**: the shortcuts a lab uses, PVWA trusting PTA, and installing
    without hardening. Only the Lab profile was tested.

</div>

For contributors, the repository has two more pages:
[DESIGN.md](https://github.com/bigbatmanorg/PASeasyInstall/blob/main/Docs/DESIGN.md) (the code, and every file
a run leaves behind) and
[VALIDATION.md](https://github.com/bigbatmanorg/PASeasyInstall/blob/main/Docs/VALIDATION.md) (what was tested
in the lab, and what is not proven).
