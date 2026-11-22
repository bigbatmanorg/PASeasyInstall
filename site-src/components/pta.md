# PTA

Installs Privileged Threat Analytics on a RHEL-family server and connects it to the Vault and to PVWA.

!!! warning "Experimental"
    Installed from clean servers in the test lab (PTA 15.2.2 on Rocky Linux 9.9 with 8 GB and 4 CPUs, Vault and
    PVWA 15.2): all PTA services run and the lab check lists PTA as connected. **The Vault does not send its
    audit to PTA yet** (syslog forwarding is not set up), so PTA sees no Vault events. RHEL 8 was not run.

There is no command of its own. PTA is part of a lab:

```powershell
$cfg = New-PASLabConfiguration -Environment MyLab -VaultMode Primary -PrimaryAddress 192.0.2.11 `
    -ControllerAddress 192.0.2.10 -Media $media -SecurityProfile Lab -AcceptEula `
    -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21' },
                 @{ Type = 'PTA';  Name = 'pta01';  Address = '192.0.2.51'; VaultTimezone = 'Europe/Berlin' })
```

In the window: *PTA* in the Custom lab; the time zone is under **Advanced** on the Servers step.

## What it needs

- **Its own server:** RHEL, Rocky or Alma 8.8+ or 9.3+ with at least **8 GB** of memory. Ubuntu is not supported
  by the vendor.
- **The root password of that server**, not only an SSH key: the vendor's configuration tool signs in as root of
  its own server.
- **A PVWA in the same lab.**
- **The PTA package** (`PTA-Installer-Rls-...zip`) **and a PSMP package** in the media: the CyberArk package
  signing key the PTA installer checks comes from the PSMP package.
- **The time zone of the Vault server** as a tz database name (`VaultTimezone` of the instance). Without it UTC
  is assumed and the plan says so.
- **`-AcceptEula`**: the license agreement of the installer.

## Steps

| Step | What it does |
|---|---|
| `media-upload` | Copies the PTA package |
| `rpm-signing-key`, `pvwa-trust-certificate` | Copies CyberArk's package signing key and, in a lab, the public certificate of PVWA |
| `preflight` | The server is of the RHEL family and has 8 GB |
| `extract`, `prerequisites` | Unpacks the package; installs what the installer needs and the signing key |
| `install` | Runs the vendor's `pta_installer.sh`, then restarts the server |
| `register` | Runs the vendor's automatic configuration tool: connects PTA to the Vault and to PVWA. Waits for the Vault, every PVWA to be finished and every CPM to be registered |
| `verify` | The PTA services run and PTA is configured for this Vault |

PTA starts when PVWA has created its certificate, shortly after the run starts, and is installed while the other
servers are installed.

After the components, one more target `trust-<pta id>` runs on the first PVWA server (Lab profile): the PVWA
server trusts the certificate PTA presents and gets a hosts entry for the PTA name.

## What the installation changes besides PTA

- SELinux is set to permissive for the one call of the configuration tool; the tool cannot sign in otherwise.
- The vendor's tool installs and enables firewalld with only its port forwarding. The recipe then opens the
  ports PTA listens on: 80, 443, 8080, 8443, 514 and 11514.

## Limits

- **No Vault events yet.** PTA analyses the Vault audit, which the Vault sends by syslog. That forwarding
  (`dbparm.ini` on the Vault, a Vault restart) is not built.
- With the Secure profile there is no way yet for PVWA to trust PTA's certificate.
- About 3.2 GB of the 8 GB were in use after the installation with the vendor's default settings; it was not
  watched under load.
