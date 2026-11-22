# Server prerequisites

What a server needs before the installation. `Test-PASPreflight`, and **Next** on the Servers step of the
window, check most of it for you without changing anything.

## Windows servers

The Vault, DR Vault, PVWA, CPM, PSM and a new domain controller run on **Windows Server 2022**. Each one needs:

- A unique computer name and a **fixed** IP address. Servers made from the same template also need their own
  machine identity (run `sysprep` on the template, as usual).
- A local administrator and its password.
- **WinRM over HTTPS (port 5986)** reachable from the controller. A self-signed certificate is fine for a lab:

    ```powershell
    $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
    winrm create winrm/config/Listener?Address=*+Transport=HTTPS "@{Hostname=`"$env:COMPUTERNAME`";CertificateThumbprint=`"$($cert.Thumbprint)`"}"
    New-NetFirewallRule -DisplayName 'WinRM HTTPS' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow
    ```

    A self-signed certificate, or one whose name is not the address you enter, needs the **Lab** profile, which
    the window always uses. See [Lab and Secure profiles](../concepts/profiles.md).

- At least 20 GB free on the system drive, and no restart pending.
- Vault and DR Vault servers must **not** be members of a domain.

A server that will be joined to a domain needs nothing special: the installation points it at the DNS server of
the domain and joins it.

## Linux servers

PSM for SSH and the HTML5 Gateway run on Ubuntu 22.04/24.04 or RHEL/Rocky 8/9; PTA on RHEL, Rocky or Alma 8.8+
or 9.3+ with 8 GB. Each one needs:

- A unique host name and a fixed address.
- **SSH (port 22)** reachable from the controller.
- **root, with its password, once.** The installation writes system packages and services, so it signs in as
  root; another account is refused at the start, even one with `sudo`. With the password the installer
  authorises a key of its own and then uses only the key. Cloud images usually block root with a password. To
  allow it while you install:

    ```bash
    sudo passwd root
    echo 'PermitRootLogin yes' | sudo tee /etc/ssh/sshd_config.d/01-install.conf
    echo 'PasswordAuthentication yes' | sudo tee -a /etc/ssh/sshd_config.d/01-install.conf
    sudo systemctl restart ssh        # sshd on the RHEL family
    ```

    Or authorise the controller's public key for root yourself: when the password does not work, the error
    message of the run shows the key to authorise.

- `jq` installed. Ubuntu and Rocky cloud images have it. `unzip` is installed by the run when it is missing, if
  the package sources of the server can be reached.
- **PTA** also needs the root password later in the run: its configuration tool signs in as root of its own
  server.

## Check from the controller

```powershell
Test-PASPreflight -Path .\MyLab.json                              # do the servers answer?
$lab = Read-Host -AsSecureString 'Lab password'
Test-PASPreflight -Path .\MyLab.json -LabPassword $lab |          # and can the accounts sign in?
    Where-Object { $_.Passed -eq $false } | Format-Table Server, Check, Detail -AutoSize
```

By hand, for one Windows server:

```powershell
$c = Get-Credential .\Administrator
Invoke-Command -ComputerName 192.0.2.11 -UseSSL -Credential $c `
    -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) -ScriptBlock { $env:COMPUTERNAME }
```

Write `.\Administrator`, with the dot, when you test by hand: a plain `Administrator` is matched against the
controller's own account first. In the window and in a configuration, keep the plain name; PASeasyInstall adds
what is needed.

## Name resolution

The installation works with addresses and needs no DNS. Two things are reached by name afterwards:

- **The web portal:** `https://<computer name of the PVWA server>/PasswordVault`. The computer with the browser
  must resolve that name; a line in its hosts file is enough.
- **The HTML5 Gateway**, the same way.

The lab check (`Test-PASHealth`, *Check the lab*) needs no name resolution.
