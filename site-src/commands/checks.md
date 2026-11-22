# Checks and diagnostics

`Test-PASPreflight` looks at the servers before an installation, `Test-PASHealth` at the lab after it.
`Export-PASDiagnostics` and `Get-PASRunLog` collect what a bug report needs. None of them changes anything on a
server.

The text of every command below is its own help (`Get-Help <command> -Full`).

| Command | What it does |
|---|---|
| [`Test-PASPreflight`](#test-paspreflight) | Checks, without changing anything, that this controller and the servers of a configuration are ready for an installation. |
| [`Test-PASHealth`](#test-pashealth) | Checks that an installed lab works: PVWA login, the components the Vault sees as connected, and DR replication. |
| [`Export-PASDiagnostics`](#export-pasdiagnostics) | Writes a sanitized ZIP of one run (configuration, plan, status and event journals) for support or documentation. |
| [`Get-PASRunLog`](#get-pasrunlog) | Reads the controller journal of a run, or the tail of a CyberArk log file on one of the lab servers. |

## Test-PASPreflight

Checks, without changing anything, that this controller and the servers of a configuration are ready for an installation.

Returns one object per check with Server, Address, Check, Passed and Detail. Passed is $true, $false, or empty ($null) when a check could not be made (for example no credential was given).

On this controller:

- Windows PowerShell 5.1 (the installer needs it);
- the configuration is valid and the installer file of every component exists;
- with a new Vault: the Vault media folder exists.

For every server of the configuration:

- the name resolves;
- the management port answers within 5 seconds: WinRM 5986 (HTTPS) or 5985 (HTTP) as the configuration says for Windows, SSH port 22 (or the configured port) for Linux.

For a Windows server, when its account is in -CredentialMap or -LabPassword is given:

- a WinRM session opens, with the same settings an installation uses;
- operating system and Windows PowerShell version;
- at least 20 GB free on the system drive;
- no restart is pending.

For a Linux server:

- sign-in works, the account is root, and the distribution is one PSMP supports. The sign-in uses the SSH key named in the configuration when it exists and is authorised already. Otherwise it uses the password of the account (-CredentialMap or -LabPassword), as the first installation does, so a wrong root password is found here. The check authorises no key.

This command never asks for a password and changes nothing on any server: it resolves names, opens connections and reads. It does not replace the preflight steps of the installation itself.

| Parameter | Meaning |
|---|---|
| `-Path` | Configuration file (JSON). |
| `-Configuration` | Configuration object, as returned by New-PASLabConfiguration or Import-PASLabConfiguration. |
| `-CredentialMap` | Server accounts: @{ &lt;server id&gt; = PSCredential }. Windows servers without an entry get the network checks only. |
| `-LabPassword` | One password for every server account of the configuration. Only for the Lab security profile. |
| `-ConnectivityOnly` | Only checks that every server answers on its management port (name resolution and TCP connect). Takes a few seconds, needs no credentials and signs in nowhere. |

```powershell
Test-PASPreflight -Path .\MyLab.json | Format-Table Server, Check, Passed, Detail -AutoSize
```

Network checks only: no credential is given.

```powershell
$lab = Read-Host -AsSecureString 'Lab password'
Test-PASPreflight -Path .\MyLab.json -LabPassword $lab | Where-Object { $_.Passed -eq $false }
```

All checks; shows only what failed.

## Test-PASHealth

Checks that an installed lab works: PVWA login, the components the Vault sees as connected, and DR replication.

Opens ONE authenticated PVWA REST session with the Vault Administrator credential and checks:

- the PVWA API answers over HTTPS. The certificate is checked normally, or pinned when -PvwaCertificateFile is given or the configuration's CPM pins one (lab self-signed PVWA); when the PVWA name does not resolve on this controller, the check connects to the PVWA address of the configuration and sends the name, so no DNS record or hosts entry is needed;
- which components the Vault reports as logged on (PVWA, CPM, PSM and PSMP);
- "PASWS383E Vault is currently under maintenance mode". This usually means PVWA started before the Vault was up; recycle the PasswordVaultWebAccessPool app pool on the PVWA server. With -DRCredential it also reads the DR server's last PADR replication cycle over WinRM. With DR configured, component password rotation fails while DR is not replicating (CASTM057E).

The session is serialised with running installations through the same Vault lock the installer uses, and is always logged off. Credentials are used in memory only and are never written anywhere. Nothing is changed in the lab.

Returns Healthy, CheckedUtc, Environment, ApiBaseUri, PvwaLogin, TlsValidation, Components, Summary, DR, Issues and Message.

PTA is listed among the components when the lab has one.

| Parameter | Meaning |
|---|---|
| `-Path` | Configuration file (JSON) that installed the lab. |
| `-Configuration` | Configuration object, as returned by New-PASLabConfiguration or Import-PASLabConfiguration. |
| `-VaultCredential` | Vault Administrator (or another Vault user allowed to read system health). |
| `-ApiBaseUri` | PVWA API base, e.g. https://pvwa01/PasswordVault/API. Default: the first PVWA of the configuration. |
| `-PvwaCertificateFile` | Public certificate (.cer) of a self-signed lab PVWA to pin. The host name must still match. |
| `-DRCredential` | Windows credential of the DR server, for the replication check. |
| `-TimeoutSeconds` | Time limit of each request (10 to 600). Default 60. |
| `-DRMaxAgeMinutes` | How old the last successful DR replication may be (5 to 1440 minutes). Default 75. |

```powershell
Test-PASHealth -Path .\MyLab.json -VaultCredential (Get-Credential Administrator)
```

```powershell
$h = Test-PASHealth -Path .\MyLab.json -VaultCredential $vault -DRCredential $dr
$h.Components | Format-Table Component, User, Address, LoggedOn, Version
```

## Export-PASDiagnostics

Writes a sanitized ZIP of one run (configuration, plan, status and event journals) for support or documentation.

Credential files, lock files and the generated payload folder (scripts and per-component inventories) are never included. Every file is scanned for private keys, credential ciphers and password fields; a file with a hit is left out and listed in the result.

Only local files of the run are read; no server is contacted. Look through the ZIP before you share it: it contains the server names and addresses of your lab.

| Parameter | Meaning |
|---|---|
| `-RunId` | Run id (32 hexadecimal characters). |
| `-Path` | ZIP file to create. Default: .\PASeasyInstall-run-&lt;RunId&gt;.zip |
| `-Force` | Replaces an existing file. |

```powershell
Export-PASDiagnostics -RunId 688d8e04f1874d41a75cda4441c00553
```

```powershell
Get-PASRun -Last 1 | Export-PASDiagnostics -Path C:\Temp\lab-run.zip -Force
```

## Get-PASRunLog

Reads the controller journal of a run, or the tail of a CyberArk log file on one of the lab servers.

Two uses:

-RunId: the raw records of the run controller's journal (events.jsonl in the run folder), oldest first. Local files only. For the merged, readable progress of a run use Get-PASRunEvent.

-Path and -Component: the last lines of a product log on the server of that component, read over WinRM (Windows, needs -Credential) or SSH (Linux, with the key of the configuration). Only the log files of the module's catalog can be read: Data\LogSources.json in the module folder lists them per component type with their names. Read-only; nothing is changed on the server.

| Parameter | Meaning |
|---|---|
| `-RunId` | Run id (32 hexadecimal characters). |
| `-Path` | Configuration file (JSON) that describes the lab. |
| `-Component` | Id of the component in the configuration, e.g. vault, pvwa01. |
| `-LogName` | Name of the log in the catalog, e.g. italog for a Vault. Default: the first log of the component type. |
| `-Credential` | Windows account for the server of the component. Required for Windows servers. |
| `-Tail` | How many of the last records or lines to return (1 to 10000). Default 200. |

```powershell
Get-PASRunLog -RunId 688d8e04f1874d41a75cda4441c00553 -Tail 20 | Format-Table timestampUtc, event, component, message
```

```powershell
Get-PASRunLog -Path .\MyLab.json -Component vault -LogName italog -Credential (Get-Credential Administrator) -Tail 100
```

Shows the last 100 lines of the Vault's ITALog.
