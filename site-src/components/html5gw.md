# HTML5 Gateway

Installs the PSM HTML5 Gateway, which shows PSM sessions in the browser, as a container on a Linux server and
enters it into the PVWA configuration.

!!! warning "Tested once"
    Installed from clean servers in the test lab: gateway package 15.0 with a 15.2 lab, on Ubuntu 24.04 with
    Docker, on the PSM for SSH server. The container runs, its health page answers and PVWA has the gateway
    entry. A session in a browser through the gateway was not part of the test. The RHEL family with Podman was
    not run.

There is no command of its own. The gateway is part of a lab:

```powershell
$cfg = New-PASLabConfiguration -Environment MyLab -VaultMode Primary -PrimaryAddress 192.0.2.11 `
    -ControllerAddress 192.0.2.10 -Media $media -SecurityProfile Lab -AcceptEula `
    -Instances @(@{ Type = 'PVWA';    Name = 'PVWA01'; Address = '192.0.2.21' },
                 @{ Type = 'PSM';     Name = 'PSM01';  Address = '192.0.2.31' },
                 @{ Type = 'PSMP';    Name = 'psmp01'; Address = '192.0.2.41' },
                 @{ Type = 'HTML5GW'; Name = 'psmp01'; Address = '192.0.2.41' })
```

In the window: the line **HTML5 Gateway (sessions in the browser)** on the Lab step. With a PSMP in the lab,
**Install the HTML5 Gateway on the PSM for SSH server (one server less)** puts both on one server.

## What it needs

- **A Linux server** with Docker (Ubuntu) or Podman (RHEL family). The container engine is installed when it is
  missing. The gateway can share the server of a PSM for SSH: give both instances the same address.
- **root**, as for [PSM for SSH](psmp.md#what-it-needs).
- **A PVWA and a PSM in the same lab.** The gateway opens PSM sessions, and it is entered into the PVWA
  configuration from the first PVWA server of the same run. Adding a gateway later to an installed lab is not
  possible yet.
- **The gateway package** (`HTML5 Gateway-Rls-...zip`) and **the PACLI package**. PACLI is used on the PVWA
  server for the registration.
- **`-AcceptEula`**: the license agreement of the installer.

## Media

In the 15.2 bundle that was tested, the 15.2.1 gateway ZIP was damaged: it cannot be unpacked. The complete 15.0
package worked with a 15.2 lab.

The media search recognises a package that is not a complete ZIP file and does not use it when another copy is
there; the Media step then says *Not used, because damaged*. So add a good gateway package as a single file next
to the bundle. When the damage cannot be seen without unpacking, the higher version is still chosen and the
installation stops at `extract`. Then choose the package yourself from the prompt:

```powershell
$inventory = Get-PASMediaInventory -Path D:\CyberArk, D:\Gateway-15.0
$media = $inventory | Get-PASMediaSelection
$media.HTML5GW = $inventory | Where-Object { $_.Component -eq 'HTML5GW' -and $_.Path -like 'D:\Gateway-15.0*' } | Select-Object -First 1
```

## Steps

| Step | What it does |
|---|---|
| `media-upload` | Copies the gateway package |
| `pvwa-trust-certificate` | Lab: copies the public certificate of PVWA; the gateway trusts it |
| `preflight`, `extract` | Checks the server and unpacks the package |
| `prerequisites` | Installs and starts Docker or Podman when it is missing |
| `install` | Runs the vendor's script `html5_console.sh`: loads the image and starts the container for the PVWA address |
| `verify` | The container runs and its health page answers |

The gateway needs no Vault, so it is installed early. When every PVWA, PSM and PTA of the run and everything on
the first PVWA server are finished, one more target `register-<gateway id>` runs on the first PVWA server
(steps `pacli-upload`, `gateway-register`): it takes `PVConfiguration.xml` out of the Vault safe `PVWAConfig`
with PACLI, adds the gateway and a reference to it in every PSM server entry, stores the file and restarts the
PVWA application.

## After the installation

The gateway listens on port 443 of its server. To open a session: sign in to PVWA, connect to an account through
PSM and choose the HTML5 connection. The computer with the browser must resolve the PVWA name and the gateway
name, and the browser warns about the gateway's own certificate.

## Limits

- The gateway creates its own certificate for its host name. A certificate of your own is not supported yet.
- With the Lab profile the gateway does not check the certificate of the PSM server.
- All PSM servers of the lab get the last gateway of the lab.
