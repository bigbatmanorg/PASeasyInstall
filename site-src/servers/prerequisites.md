# Server prerequisites

## Windows servers

Vault, DR, PVWA, CPM, PSM and the optional domain controller run on **Windows Server 2022**. Each one needs:

- A unique computer name (`PAS-VAULT`, `PAS-PVWA`, …), a unique machine SID and a **static** IP address.
- A local Administrator account and its password, which you enter in the desktop.
- **WinRM over HTTPS (TCP 5986)** reachable from the controller. A self-signed certificate is fine for a lab:

    ```powershell
    $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
    winrm create winrm/config/Listener?Address=*+Transport=HTTPS "@{Hostname=`"$env:COMPUTERNAME`";CertificateThumbprint=`"$($cert.Thumbprint)`"}"
    New-NetFirewallRule -DisplayName 'WinRM HTTPS' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow
    ```

    If the certificate is self-signed or its name does not match the address you enter, use the **Lab** profile. It
    allows exactly that, and lists it as a deviation on the Review plan step. See
    [Lab and Secure profiles](../concepts/profiles.md).

- Vault and DR servers must **not** be domain-joined.
- The server that becomes the **domain controller** must use itself as DNS server before the installation:
  `Set-DnsClientServerAddress -InterfaceAlias Ethernet -ServerAddresses <its own address>`. The forest's DNS zone lives on it.


## PSMP (Linux)

- Ubuntu 24.04 (or RHEL/Rocky 8/9), with a static address and a unique hostname.
- `jq` installed (included in Ubuntu and Rocky cloud images). `unzip` is installed by the run when missing.
- SSH (TCP 22) from the controller, signing in as **`root`**: the installation writes system packages, services and
  `/opt/paeasyinstall`, so other accounts (even with `sudo`) are refused at the start with a clear message.
  Allow `root` to sign in **with its password once**, so PASeasyInstall can authorise its own key, or authorise the
  controller's public key for `root` yourself when the run asks for it. Cloud images usually block this; for
  example, set a root password and add `PermitRootLogin yes` to a file in `/etc/ssh/sshd_config.d/` while you install.

## Check from the controller

```powershell
$c = Get-Credential .\Administrator
Invoke-Command -ComputerName 10.10.0.11 -UseSSL -Credential $c `
  -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) -ScriptBlock { $env:COMPUTERNAME }
```

Use `.\Administrator` (with the dot), not plain `Administrator`, when testing by hand. See
[Troubleshooting](../troubleshooting/index.md#winrm-access-is-denied-with-administrator).
