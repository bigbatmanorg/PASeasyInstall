# 6 Install

![Step 6 before installing: readiness list and the Install button](../assets/screenshots/6-install-ready.png)

## Ready to install

A short checklist next to the **Install** button: plan reviewed, project file, credentials, deployment. Install is
enabled once the plan has no blocking issues.

Clicking **Install**:

1. saves the project file;
2. hands the credentials, in memory, to a **detached controller process** on this computer;
3. starts the deployment: the Vault (and DR) first, then the component servers, one at a time or in parallel.

Closing the window does **not** stop the installation. Reopen the desktop or use
[`Get-PASEnvironmentSnapshot`](../commands/snapshot-events.md) to follow it.

## Progress

![Step 6 while installing: one card per server with stage chips](../assets/screenshots/6-install-progress.png)

One card per server, with a chip per stage that turns green when it completes, the current stage highlighted, and
`n / m stages`. Below it is the **event log**, newest first, read from the controller's event journals. There are no
estimated percentages: what you see is what the servers reported.

## When something fails

![A failed stage: the failed chip in red and the reason in the event log](../assets/screenshots/6-install-failed.png)

The failed stage turns red, and the event log shows the reason. Nothing new starts after a failure, and the remaining
servers are marked as skipped. The attempt's state on the server is recorded. Read
[Troubleshooting](../troubleshooting/index.md), fix the cause, then resume with
[`Resume-PASeasyDeployment`](../commands/resume.md). Never reinstall blindly over an uncertain attempt.

*The progress and failure screenshots use the Mock backend.*
