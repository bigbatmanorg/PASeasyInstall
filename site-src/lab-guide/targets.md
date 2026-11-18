# Preparing target servers

## Windows template

Build one Windows Server 2022 template and clone every Windows target from it:

1. Install Windows Server 2022, apply updates, and install the hypervisor guest tools.
2. Enable WinRM over HTTPS (5986) with a self-signed certificate, and allow it in the firewall:

    ```powershell
    $cert = New-SelfSignedCertificate -DnsName $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My
    winrm create winrm/config/Listener?Address=*+Transport=HTTPS "@{Hostname=`"$env:COMPUTERNAME`";CertificateThumbprint=`"$($cert.Thumbprint)`"}"
    New-NetFirewallRule -DisplayName 'WinRM HTTPS' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow
    ```

3. **Sysprep** (generalize) and convert to a template, so every clone gets a unique SID and hostname.

With a template-built certificate, use the **Lab** profile: the certificate name will not match the clones.

## Each Windows clone

- A unique, meaningful hostname (`PAS-VAULT`, `PAS-PVWA`, …) and a **static** IP address.
- The local Administrator password you will enter in the desktop.
- Vault and DR servers must **not** be domain-joined.

## PSMP (Linux)

- Ubuntu 24.04 cloud image (or RHEL/Rocky 8/9), static address and hostname.
- `apt-get install -y unzip`.
- Allow `root` (or your chosen account) to sign in **with the password once**, so PASeasyInstall can authorise its key.
  Or authorise the controller's public key yourself when the run asks for it.

## Check from the controller

```powershell
$c = Get-Credential .\Administrator
Invoke-Command -ComputerName 10.10.0.11 -UseSSL -Credential $c `
  -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) -ScriptBlock { $env:COMPUTERNAME }
```

Use `.\Administrator` (with the dot), not plain `Administrator`, when testing by hand. See
[Troubleshooting](../troubleshooting/index.md#winrm-access-is-denied-with-administrator).
