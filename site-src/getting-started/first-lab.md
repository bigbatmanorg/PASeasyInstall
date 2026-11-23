# Your first lab

This page builds a full lab: a Vault with a DR Vault, PVWA and CPM on one server, PSM, and PSM for SSH. It
needs five servers. For a smaller start set PSM and PSM for SSH to 0 and choose *New Vault* (Vault, PVWA and CPM: two servers); every step is the same.

The addresses below are examples. Use your own.

| Server | Computer name | Address | Operating system |
|---|---|---|---|
| Controller | (this computer) | 10.0.0.10 | Windows with Windows PowerShell 5.1 |
| Vault | any | 10.0.0.11 | Windows Server 2022, not in a domain |
| DR Vault | any | 10.0.0.12 | Windows Server 2022, not in a domain |
| PVWA and CPM | PVWA01 | 10.0.0.21 | Windows Server 2022 |
| PSM | PSM01 | 10.0.0.31 | Windows Server 2022 |
| PSM for SSH | psmp01 | 10.0.0.41 | Ubuntu 24.04 |

## 1. Prepare the servers

Install the operating systems, give every server its computer name and a fixed address.

On every **Windows** server, make WinRM answer over HTTPS. A self-signed certificate is fine for a lab:

```powershell
$cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
winrm create winrm/config/Listener?Address=*+Transport=HTTPS "@{Hostname=`"$env:COMPUTERNAME`";CertificateThumbprint=`"$($cert.Thumbprint)`"}"
New-NetFirewallRule -DisplayName 'WinRM HTTPS' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow
```

On the **Linux** server, root must be able to sign in over SSH with its password once. On a cloud image that
usually means: set a root password and allow it while you install.

```bash
sudo passwd root
echo 'PermitRootLogin yes' | sudo tee /etc/ssh/sshd_config.d/01-install.conf
echo 'PasswordAuthentication yes' | sudo tee -a /etc/ssh/sshd_config.d/01-install.conf
sudo systemctl restart ssh
```

More, and how to test a server by hand: [Server prerequisites](../servers/prerequisites.md).

## 2. Put the media on the controller

Copy your CyberArk download, `license.xml` and `recpub.key` to the controller. They can lie in different folders,
for example `D:\CyberArk` for the download and `D:\Licenses` for the license and the key.

## 3. Open the window

```powershell
Start-PASeasyInstall
```

From the portable ZIP: double-click `Start-PASeasyInstall.cmd`. Press **Start a new lab**.

### Media

Type the path of the folder with your download and press **Add**, or use **Choose a folder...**. Add the folder
with the license and the key the same way. The window lists every place with what it found there, and below it
every installer with its version.

![Media step with three places added](../assets/window/04-media-sources.png)

### Lab

Choose **New Vault with DR** and set PVWA, CPM, PSM and PSM for SSH to 1. Leave *Install CPM on the PVWA server* switched on and *No domain* selected. Give the lab a name,
for example `PamLab`.

![Lab step with a Vault, a DR Vault and one of each component](../assets/window/06-lab.png)

### Servers

Enter the computer name (where the window asks for one), the address and the password of every server. The
account is `Administrator` on Windows and `root` on Linux unless you change it. Below, type the passwords to set
for the Vault users Administrator and Master and for the DR user, and accept the license agreement of the Linux
installers.

![Servers step, filled in](../assets/window/09-servers.png)

Press **Next: check the servers**. The window first looks whether every server answers, then signs in to each
one. A server that does not answer, or a password that is wrong, is named with the reason. Nothing is installed.

### Install

Read the plan. *Lab shortcuts in use* lists what the Lab profile relaxes. Press **Install the lab** and confirm.

![Review step](../assets/window/12-review.png)

## 4. Watch it run

Every server starts at once. The Vault is installed while PVWA, PSM and PSM for SSH are installed and hardened
on their servers. A component that is ready to register shows *Waiting for its turn at the Vault* until the
Vault, and with a DR Vault its replication, is ready. Then they register one at a time.

![The installation page while it runs](../assets/window/15-run-installing.png)

PSM restarts its server several times. That is expected. You can close the window; the installation goes on and
the start page lists it when you open the window again.

In the test lab this lab took 23 minutes (CyberArk 15.2, servers with 2 CPUs and 4 GB).

## 5. Check the lab

When the page says **The lab is installed**, press **Check the lab**. It signs in to the Vault through PVWA and
lists the components the Vault sees as connected.

![The lab check: every component is connected](../assets/window/19-lab-check.png)

Then open the web portal: `https://PVWA01/PasswordVault`. Sign in as `Administrator` with the Vault Administrator
password you set. Two things to know in a lab:

- The computer with the browser must resolve the PVWA name. A line in its hosts file is enough:
  `10.0.0.21 PVWA01`.
- The PVWA certificate is self-signed, so the browser warns. Accept it, or import the certificate.

## If it stops

The page shows the step that stopped and the installer's own error text. Correct the cause on the server, then
press **Try this step again**. See [The installation page](../gui/run.md#stopped) and
[Troubleshooting](../troubleshooting/index.md).

## The same lab from the prompt

```powershell
$media = Get-PASMediaInventory -Path D:\CyberArk, D:\Licenses | Get-PASMediaSelection
$cfg = New-PASLabConfiguration -Environment PamLab -VaultMode PrimaryDR `
        -PrimaryAddress 10.0.0.11 -DRAddress 10.0.0.12 -ControllerAddress 10.0.0.10 `
        -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '10.0.0.21' },
                     @{ Type = 'CPM';  Name = 'CPM01';  Address = '10.0.0.21' },
                     @{ Type = 'PSM';  Name = 'PSM01';  Address = '10.0.0.31' },
                     @{ Type = 'PSMP'; Name = 'psmp01'; Address = '10.0.0.41' }) `
        -Media $media -SecurityProfile Lab -AcceptEula
Export-PASLabConfiguration -Configuration $cfg -Path .\PamLab.json

Test-PASPreflight -Path .\PamLab.json          # do the servers answer?
Install-PASLab -Path .\PamLab.json -Wait       # asks for the accounts and passwords, then installs
Test-PASHealth -Path .\PamLab.json -VaultCredential (Get-Credential Administrator)
```

Two instances with the same address share one server, as PVWA and CPM do here. Each command is explained in
[Commands](../commands/index.md).
