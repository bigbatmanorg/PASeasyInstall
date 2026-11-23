# HTML5 Gateway

Installs the PSM HTML5 Gateway, which shows PSM sessions in the browser, as a container on a Linux server and
enters it into the PVWA configuration.

!!! warning "Experimental"
    Installed once from clean servers in the test lab (gateway 15.0 with a 15.2 lab, Ubuntu 24.04 with Docker, on
    the PSM for SSH server): the container runs, its health page answers and PVWA has the gateway entry. **A
    session in a browser through the gateway was not opened yet.** The RHEL family with Podman was not run.

There is no command of its own. The gateway is part of a lab:

```powershell
$cfg = New-PASLabConfiguration -Environment MyLab -VaultMode Primary -PrimaryAddress 192.0.2.11 `
    -ControllerAddress 192.0.2.10 -Media $media -SecurityProfile Lab -AcceptEula `
    -Instances @(@{ Type = 'PVWA';    Name = 'PVWA01'; Address = '192.0.2.21' },
                 @{ Type = 'PSM';     Name = 'PSM01';  Address = '192.0.2.31' },
                 @{ Type = 'PSMP';    Name = 'psmp01'; Address = '192.0.2.41' },
                 @{ Type = 'HTML5GW'; Name = 'psmp01'; Address = '192.0.2.41' })
```

In the window: the *HTML5 Gateway* counter on the Lab step.

## What it needs

- **A Linux server** with Docker (Ubuntu) or Podman (RHEL family). The container engine is installed when it is
  missing. The gateway can share the server of a PSM for SSH: give both instances the same address.
- **root**, as for [PSM for SSH](psmp.md#what-it-needs).
- **A PVWA in the same lab.** The gateway is entered into the PVWA configuration from the PVWA server of the
  same run. Adding a gateway later to an installed lab is not possible yet.
- **The gateway package** (`HTML5 Gateway-Rls-...zip`) and **the PACLI package**. PACLI is used on the PVWA
  server for the registration.
- **`-AcceptEula`**: the license agreement of the installer.

## Media

The gateway package inside the 15.2 big ZIP is cut short and cannot be unpacked; the `extract` step says so.
The complete 15.0 package works with a 15.2 lab. Because the highest version found is chosen, choose the 15.0
package yourself when both are there:

```powershell
$inventory = Get-PASMediaInventory -Path D:\CyberArk, D:\Gateway-15.0
$media = $inventory | Get-PASMediaSelection
$media.HTML5GW = $inventory | Where-Object { $_.Component -eq 'HTML5GW' -and $_.Path -like 'D:\Gateway-15.0*' } | Select-Object -First 1
```

In the window the file cannot be chosen yet: when both packages are found, the higher version is taken and the
installation stops at `extract`. For a lab with the 15.2 big ZIP and a gateway, use the commands above.

## Steps

| Step | What it does |
|---|---|
| `media-upload` | Copies the gateway package |
| `pvwa-trust-certificate` | Lab: copies the public certificate of PVWA; the gateway trusts it |
| `preflight`, `extract` | Checks the server and unpacks the package |
| `prerequisites` | Installs and starts Docker or Podman when it is missing |
| `install` | Runs the vendor's script `html5_console.sh`: loads the image and starts the container for the PVWA address |
| `verify` | The container runs and its health page answers |

After the components of the run, one more target `register-<gateway id>` runs on the first PVWA server: it takes
`PVConfiguration.xml` out of the Vault safe `PVWAConfig` with PACLI, adds the gateway and a reference to it in
every PSM server entry, stores the file and restarts the PVWA application.

## After the installation

The gateway listens on port 443 of its server. To open a session: sign in to PVWA, connect to an account through
PSM and choose the HTML5 connection. The computer with the browser must resolve the PVWA name and the gateway
name, and the browser warns about the gateway's own certificate.

## Limits

- The gateway creates its own certificate for its host name. A certificate of your own is not supported yet.
- With the Lab profile the gateway does not check the certificate of the PSM server.
- All PSM servers of the lab get the last gateway of the lab.
