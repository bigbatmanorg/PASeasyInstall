# Preparing servers

PASeasyInstall installs CyberArk PAM on servers you provide. It does not create them. Use virtual machines,
physical machines or cloud instances, whatever your lab runs on. Use machines you can throw away: an
installation changes and hardens them.

<div class="grid cards" markdown>

-   **[Which servers a lab needs](roles.md)**: the servers of a lab, their sizes, and how to make a lab
    smaller.
-   **[Server prerequisites](prerequisites.md)**: what a Windows and a Linux server needs before the
    installation, and how to test it from the controller.

</div>

!!! tip "Keep a clean state"
    Take a snapshot of every server when it is prepared and before anything is installed. An installation cannot
    be undone from PASeasyInstall; going back to the snapshot is how you start again.
