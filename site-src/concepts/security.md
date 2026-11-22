# Security

## Passwords

- **Passwords live in memory only.** The window keeps them in its password fields as protected strings. They
  never appear in a lab file, a log, a journal, a command line or anything the window shows.
- **Handing them to the installation.** The controller process of a run gets the accounts in a file that is
  protected with Windows DPAPI, readable only by the same Windows user on the same computer. The file is deleted
  as soon as the process has read it. This is why an installation must be started from a local session.
- **On the servers**, the inputs of a step that hold a secret are protected and deleted after use. Vault
  passwords reach the vendor's tools through a private pipe, never on a command line.
- **Nothing is stored for later.** To continue a run, the accounts and passwords are entered again.

## Connections

- **Windows servers:** WinRM over HTTPS. Each server gets a restricted endpoint that only the configured
  administrator may use.
- **Linux servers:** SSH with a key the controller creates for the lab. The password of root is used once, to
  authorise that key. With the Lab profile the host key of the server is trusted on first use and written to the
  log; the Secure profile requires a host key that is known already.
- **The hardened Vault** accepts management connections only from the address of the controller.

## Hardening

Every component is hardened with CyberArk's own hardening scripts, and the result is checked. In a lab that
creates its domain, the CyberArk hardening GPOs from the vendor packages are applied to the joined servers.
A lab can be installed [without hardening](profiles.md#installing-without-hardening) for tests.

## What it does not do

- It collects no telemetry and contacts no service besides your servers. The PowerShell Gallery is contacted
  only when you install from it.
- It ships no CyberArk file, license or key.
- It is not code-signed; see [Execution policy](../getting-started/execution-policy.md).

## What is not proven

Only the **Lab** profile was tested. It relaxes several checks on purpose; they are listed on
[Lab and Secure profiles](profiles.md). Do not take a lab built this way as a model for production.
