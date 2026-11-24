# PTA

Installs Privileged Threat Analytics on a RHEL-family server and connects it to the Vault and to PVWA.

!!! warning "Registered and connected, but not complete yet"
    Tested from clean servers: PTA 15.2.2 on Rocky Linux 9.9 with 8 GB and 4 CPUs, Vault and PVWA 15.2, Lab
    profile, in a full lab through the window (2.0.11, 2026-11-24). All PTA services run, PTA is registered in
    the Vault and PVWA System Health and the lab check show it connected. **The Vault does not send its audit to
    PTA yet** (syslog forwarding is not set up), so PTA sees no Vault events. RHEL 8 was not run.

There is no command of its own. PTA is part of a lab:

```powershell
$cfg = New-PASLabConfiguration -Environment MyLab -VaultMode Primary -PrimaryAddress 192.0.2.11 `
    -ControllerAddress 192.0.2.10 -Media $media -SecurityProfile Lab -AcceptEula `
    -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21' },
                 @{ Type = 'PTA';  Name = 'pta01';  Address = '192.0.2.51'; VaultTimezone = 'Europe/Berlin' })
```

In the window: the line **PTA (threat analytics)** on the Lab step; the time zone is under **Advanced** on the
Servers step.

## What it needs

- **Its own server:** RHEL, Rocky or Alma 8.8+ or 9.3+ with at least **8 GB** of memory. Ubuntu is not supported
  by the vendor. The server check on the Servers step tells you when the server is something else.
- **The root password of that server**, not only an SSH key: the vendor's configuration tool signs in as root of
  its own server.
- **A PVWA in the same lab.**
- **One PTA per lab.** Every PTA registers in the Vault as the same Vault user, `PTAAppUser`: a second PTA
  takes the Vault connection over from the first, and PVWA counts one PTA. This was tried on two PTA servers of
  one lab (2026-11-24): both configurations ended without an error, but only the PTA registered last signed in to
  the Vault afterwards. The vendor's redundancy for PTA is a Primary with a DR Secondary
  (`promoteDemote.sh`), which PASeasyInstall does not set up. The window offers one PTA, and a new installation
  with more than one is refused.
- **The PTA package** (`PTA-Installer-Rls-...zip`) **and a PSMP package** in the media: the CyberArk package
  signing key the PTA installer checks comes from the PSMP package. A PSMP in the lab is not needed.
- **The time zone of the Vault server** as a tz database name (`VaultTimezone` of the instance). Without it UTC
  is assumed and the plan says so.
- **`-AcceptEula`**: the license agreement of the installer.

## Steps

| Step | What it does |
|---|---|
| `media-upload` | Copies the PTA package |
| `rpm-signing-key`, `pvwa-trust-certificate` | Copies CyberArk's package signing key and, in a lab, the public certificate of PVWA |
| `preflight` | The server is of the RHEL family and has 8 GB |
| `extract` | Unpacks the package |
| `prerequisites` | Installs `sshpass`, `unzip` and `tar` (from EPEL when needed) and imports the signing key; checks the signature of PTA's SELinux policy package |
| `install`, `install-reboot` | Runs the vendor's `pta_installer.sh`, then restarts the server |
| `register` | Runs the vendor's automatic configuration (`ptaAutomaticConfiguration.py`): connects PTA to the Vault and to PVWA. Waits for the Vault, for every PVWA to be finished, and for every CPM, PSM and PSMP to be registered |
| `verify` | The PTA service manager runs, the PTA web application answers with its version, and PTA is configured for this Vault |

PTA starts when PVWA has created its certificate, shortly after the run starts, and is installed while the other
servers are installed. **It registers last**: its configuration holds the Vault for about three minutes, so
PSM and PSM for SSH go first.

Before the configuration, `register` makes the PTA server resolve the PVWA name and its own host name (hosts
entries when there is no DNS), and puts the PVWA certificate into the trust stores of PTA's Java. With several
PVWAs that is a bundle of all their certificates; each one is imported on its own (aliases `paseasy-pvwa`,
`paseasy-pvwa-2`, ...), because Java's `keytool -importcert` takes one certificate at a time. Before 2.0.17 the
bundle was imported whole, and with two PVWAs `register` failed after a second, with only *Warning: use -cacerts
option* in its output.

## PVWA trusts PTA

PVWA reaches PTA under PTA's own host name: the name in PTA's self-signed certificate, which is the name PTA
registers in the Vault. PVWA calls `https://<that name>/api/getauthtoken`, for example for System Health and the
lab check.

So, with the Lab profile, one more target `trust-<pta id>` runs on the first PVWA server when PVWA and PTA are
finished (step `pta-trust`, *Making PVWA trust PTA*):

- it puts the certificate PTA presents into the trusted roots of the PVWA server (trusted on first use, listed
  as a security deviation in the run log);
- it adds a hosts entry for every name in that certificate that does not lead to the PTA address;
- its check makes a real HTTPS call to PTA by that name. A missing name or trust fails here, not later in the
  lab check.

Before 2.0.11 only the name typed in the window got a hosts entry. A PTA server whose real host name was
different was then shown as not connected, and the lab check said *No PTA is registered in the Vault*. Now the
lab check says *PTA is registered in the Vault ..., but PVWA cannot reach it* when PVWA cannot reach PTA by its
name.

## What the installation changes besides PTA

- SELinux is set to permissive for the one call of the configuration tool and set back afterwards; the tool
  cannot sign in otherwise.
- The vendor's tool installs and enables firewalld with only its port forwarding. The recipe then opens the
  ports PTA listens on: 80, 443, 8080, 8443, 514 and 11514.
- `/etc/hosts` of the PTA server and of the first PVWA server get entries for the names above.

## Limits

- **No Vault events yet.** PTA analyses the Vault audit, which the Vault sends by syslog. That forwarding
  (the syslog settings in `dbparm.ini` on the Vault, and a Vault restart) is not built.
- With the Secure profile there is no way yet for PVWA to trust PTA's certificate: the `trust-<pta id>` target
  runs with the Lab profile only.
- About 3.2 GB of the 8 GB were in use after the installation with the vendor's default settings; it was not
  watched under load.
