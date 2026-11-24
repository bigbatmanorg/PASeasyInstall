# Install commands

Each command installs one thing and returns a run id at once; the installation runs in its own process. Add
`-Wait` to follow it, `-WhatIf` to see what would happen without asking or contacting anything.

`Install-PASLab` installs a whole lab from a configuration, with all its servers at the same time. The other
commands install one component for a Vault that exists already. The HTML5 Gateway and PTA have no command of
their own: they are installed as part of a lab configuration (`New-PASLabConfiguration -Instances`).

The text of every command below is its own help (`Get-Help <command> -Full`).

| Command | What it does |
|---|---|
| [`Install-PASLab`](#install-paslab) | Installs everything a lab configuration describes: Vault, DR, PVWA, CPM, PSM, PSMP, HTML5 Gateway, PTA, Active Directory. |
| [`Install-PASVault`](#install-pasvault) | Installs a CyberArk Primary Vault, or a Primary and DR Vault pair, on servers you provide. |
| [`Install-PASPVWA`](#install-paspvwa) | Installs CyberArk Password Vault Web Access (PVWA) on a Windows server and registers it with an existing Vault. |
| [`Install-PASCPM`](#install-pascpm) | Installs the CyberArk Central Policy Manager (CPM) on a Windows server and registers it with an existing Vault. |
| [`Install-PASPSM`](#install-paspsm) | Installs the CyberArk Privileged Session Manager (PSM) on a Windows server and registers it with an existing Vault. |
| [`Install-PASPSMP`](#install-paspsmp) | Installs the CyberArk PSM for SSH proxy (PSMP) on a Linux server and registers it with an existing Vault. |
| [`Install-PASDomainController`](#install-pasdomaincontroller) | Creates a new Active Directory forest for a lab on a Windows server (first domain controller). |

## Install-PASLab

Installs everything a lab configuration describes: Vault, DR, PVWA, CPM, PSM, PSMP, HTML5 Gateway, PTA, Active Directory.

Takes a configuration file (written by Export-PASLabConfiguration or saved by the desktop wizard) or a configuration object (from New-PASLabConfiguration). The servers are installed at the same time. A step that signs in to the Vault waits until the Primary Vault is installed; the registrations then run one at a time, in this order: the first PVWA, the other PVWAs, every CPM, then PSM and PSMP, and PTA last. The HTML5 Gateway is entered into the PVWA configuration when PVWA, PSM and the gateway are installed. A server that fails stops only what depends on it. A configuration with execution.mode Sequential installs one component after the other instead: Active Directory, domain joins, Vault and DR, then PVWA, CPM, PSM, PSMP, HTML5 Gateway, PTA.

The command validates the configuration and the installer media and asks for confirmation. Only then it asks for every server account and password that -CredentialMap, -SecretMap or -LabPassword do not supply. With -WhatIf nothing is asked and nothing is contacted. Get-PASCredentialRequirement lists what a configuration needs; Get-PASLabPlan shows what would be installed.

The installation runs in a detached controller process and keeps running when you close the console. The command returns the run id; follow the run with Wait-PASRun or Get-PASRun, or use -Wait. A run that stopped is continued with Resume-PASRun.

Passwords are kept in memory only. They are never written to the configuration, a log or a command line. PASeasyInstall builds labs. Production use is at your own risk.

A lab configuration can also hold an HTML5 Gateway, PTA and a domain; see [`New-PASLabConfiguration`](configuration.md#new-paslabconfiguration).

| Parameter | Meaning |
|---|---|
| `-Path` | Configuration file (JSON). |
| `-Configuration` | Configuration object, as returned by New-PASLabConfiguration or Import-PASLabConfiguration. |
| `-CredentialMap` | Server accounts: @{ &lt;server id&gt; = PSCredential }. The server ids are the keys of "hosts" in the configuration. Servers that are missing here are asked for. |
| `-SecretMap` | Passwords as SecureString: @{ VaultAdmin = ...; VaultMaster = ...; DRPassword = ...; ADSafeMode = ...; DomainJoinPassword = ... }. Only the ones the configuration needs; missing ones are asked for. |
| `-LabPassword` | One password for every server and every secret that is not supplied otherwise. Only for a configuration with the Lab security profile. |
| `-Wait` | Shows the progress until the run ends and returns the final run (see Wait-PASRun). |
| `-PollSeconds` | With -Wait: seconds between two progress checks. Default 15. |

```powershell
Install-PASLab -Path .\MyLab.json -Wait
```

Asks for the accounts and passwords the lab needs, installs it and shows the progress.

```powershell
$lab = Read-Host -AsSecureString 'Lab password'
$id = Install-PASLab -Path .\MyLab.json -LabPassword $lab
Get-PASRun -RunId $id
```

Starts the installation with one lab password and looks at the run.

```powershell
$creds = @{ vault01 = (Get-Credential Administrator); pvwa01 = (Get-Credential Administrator) }
$secrets = @{ VaultAdmin = (Read-Host -AsSecureString 'Vault Administrator'); VaultMaster = (Read-Host -AsSecureString 'Vault Master') }
Install-PASLab -Configuration $cfg -CredentialMap $creds -SecretMap $secrets -Confirm:$false
```

Unattended start with everything supplied.

## Install-PASVault

Installs a CyberArk Primary Vault, or a Primary and DR Vault pair, on servers you provide.

Installs and hardens the Primary Vault on -ComputerName. With -DRComputerName a DR Vault is installed on a second server in the same run and replication is verified. A DR Vault can only be installed together with a new Primary Vault: adding DR to a Vault that already exists is not supported.

The installer media (Vault server, PACLI, for DR the Disaster Recovery package, license, recovery public key, VC++ runtimes) is looked up in -MediaPath by file name. Get-PASMediaInventory shows what is recognised there.

The command validates everything first and asks for confirmation. Only then it asks for what you did not pass: the Windows account of each server and the Vault passwords. With -WhatIf nothing is asked and nothing is contacted. The installation runs in a detached controller process and keeps running when you close the console. The command returns the run id; follow the run with Wait-PASRun or Get-PASRun, or use -Wait.

Passwords are kept in memory only. They are never written to a file, a log or a command line. PASeasyInstall builds labs. Production use is at your own risk.

| Parameter | Meaning |
|---|---|
| `-ComputerName` | IP address or DNS name of the server that becomes the Primary Vault. A dedicated Windows server that is not a domain member. |
| `-DRComputerName` | IP address or DNS name of the server that becomes the DR Vault. Leave it out for a Primary only. |
| `-MediaPath` | Folder that holds the CyberArk Vault installer media: the full bundle ZIP, or the Server, PACLI, Disaster Recovery and "Vault Ansible Role" ZIPs, with license.xml, recpub.key and the VC++ runtimes. |
| `-ControllerAddress` | IPv4 address of this controller as the Vault servers see it. The hardened Vault firewall is opened for it. Default: the local address that routes to -ComputerName. |
| `-Name` | Name of the environment (letters, digits, dot, dash, underscore). Runs are listed under it. Default: MyPAM. |
| `-Credential` | Local administrator of the Primary Vault server. Asked for when missing. The default account name is Administrator; to use another account pass it here. |
| `-DRCredential` | Local administrator of the DR server. The account name must be the same as on the Primary; the password may differ. Asked for when missing. |
| `-VaultAdminPassword` | Password to set for the Vault user Administrator. Printable ASCII without double quotes. |
| `-MasterPassword` | Password to set for the Vault user Master. Printable ASCII without double quotes. |
| `-DRPassword` | Password to set for the Vault DR user. Only with -DRComputerName. |
| `-LabPassword` | One password for every server account and every Vault password. Only with -SecurityProfile Lab. |
| `-SecurityProfile` | Secure (default): WinRM over HTTPS with a trusted certificate, no RDP to the hardened Vault. Lab: accepts self-signed WinRM certificates and keeps RDP from the controller to the Vault open. Every lab deviation is listed as a warning. Only the Lab profile was tested; Secure is not qualified. |
| `-LicenseFile` | Vault license (.xml). Default: the license found in -MediaPath. |
| `-RecoveryPublicKey` | Recovery public key file (recpub.key), or the folder that contains it. Default: the key found in -MediaPath. |
| `-Wait` | Shows the progress until the run ends and returns the final run (see Wait-PASRun). |
| `-PlanOnly` | Validates the input and returns the plan. Asks nothing and contacts no server. |

```powershell
Install-PASVault -ComputerName 192.0.2.11 -MediaPath D:\CyberArkMedia -Wait
```

Installs a Primary Vault with the Secure profile. Asks for the server account and the two Vault passwords, then shows the progress.

```powershell
$lab = Read-Host -AsSecureString 'Lab password'
Install-PASVault -ComputerName 192.0.2.11 -DRComputerName 192.0.2.12 -MediaPath D:\CyberArkMedia -SecurityProfile Lab -LabPassword $lab
```

Installs a Primary and DR pair in a lab with one password for everything. Returns the run id.

```powershell
Install-PASVault -ComputerName 192.0.2.11 -MediaPath D:\CyberArkMedia -WhatIf
```

Validates the input and says what would be installed. Nothing is asked or contacted.

## Install-PASPVWA

Installs CyberArk Password Vault Web Access (PVWA) on a Windows server and registers it with an existing Vault.

Uploads the installer, installs the prerequisites and PVWA, binds the HTTPS certificate, registers PVWA with the Vault, applies the vendor hardening and verifies the result.

-MediaPath is the PVWA installer ZIP itself, or a folder or CyberArk bundle ZIP that contains it; the newest matching package is used.

The command validates everything first and asks for confirmation. Only then it asks for what you did not pass: the Windows account of the server and the password of the Vault user Administrator. With -WhatIf nothing is asked and nothing is contacted. The installation runs in a detached controller process and keeps running when you close the console. The command returns the run id; follow the run with Wait-PASRun or Get-PASRun, or use -Wait.

Passwords are kept in memory only. PASeasyInstall builds labs. Production use is at your own risk.

| Parameter | Meaning |
|---|---|
| `-ComputerName` | IP address or DNS name of the server to install PVWA on. |
| `-VaultAddress` | IP address or DNS name of the Vault the component registers with. |
| `-MediaPath` | The PVWA installer ZIP, or a folder or CyberArk bundle ZIP that contains it. |
| `-Name` | Name of the environment (letters, digits, dot, dash, underscore). Runs are listed under it. Default: MyPAM. |
| `-Credential` | Local administrator of the server (or a domain account that is administrator there). Asked for when missing. The default account name is Administrator; to use another account pass it here. |
| `-VaultAdminPassword` | Password of the Vault user Administrator, used to register the component. Asked for when missing. |
| `-LabPassword` | One password for the server account and the Vault Administrator. Only with -SecurityProfile Lab. |
| `-SecurityProfile` | Secure (default): WinRM over HTTPS with a trusted certificate, and PVWA uses the certificate you name with -CertificateThumbprint. Lab: accepts self-signed WinRM certificates and creates a self-signed PVWA certificate. Every lab deviation is listed as a warning. Only the Lab profile was tested; Secure is not qualified. |
| `-Options` | Further recipe options as a hashtable. They are stored in the configuration (components[].options) and win over the defaults. Supported for PVWA: pvwaUrl, tlsCertificateThumbprint, createLabCertificate, installDirectory, applicationDirectory, applicationName, vaultPort. |
| `-PvwaUrl` | HTTPS URL users will open, with one application path, e.g. https://pvwa01.pam.lab/PasswordVault (option pvwaUrl). Default: https://&lt;ComputerName&gt;/PasswordVault when -ComputerName is a DNS name, otherwise https://&lt;computer name of the server&gt;/PasswordVault. |
| `-CertificateThumbprint` | Thumbprint of the HTTPS certificate for PVWA. The certificate with its private key must already be in the LocalMachine\My store of the server (option tlsCertificateThumbprint). Required with the Secure profile. With the Lab profile a self-signed certificate is created when you leave it out. |
| `-Wait` | Shows the progress until the run ends and returns the final run (see Wait-PASRun). |
| `-PlanOnly` | Validates the input and returns the plan. Asks nothing and contacts no server. |

```powershell
Install-PASPVWA -ComputerName pvwa01.pam.lab -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -CertificateThumbprint 9F2C6E0B7D1A4C35A8E2B4D6F8091A2B3C4D5E6F -Wait
```

Installs PVWA with an existing certificate. Asks for the server account and the Vault Administrator password, then shows the progress.

```powershell
$lab = Read-Host -AsSecureString 'Lab password'
Install-PASPVWA -ComputerName 192.0.2.21 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -SecurityProfile Lab -LabPassword $lab
```

Lab install with a self-signed certificate and one password. Returns the run id.

```powershell
Install-PASPVWA -ComputerName 192.0.2.21 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -SecurityProfile Lab -PlanOnly
```

Validates the input and returns the plan.

## Install-PASCPM

Installs the CyberArk Central Policy Manager (CPM) on a Windows server and registers it with an existing Vault.

Uploads the installer, installs the prerequisites and CPM, sets up the trust to PVWA, registers CPM with the Vault, applies the vendor hardening and verifies the result. Install PVWA first: the CPM registration needs the PVWA environment in the Vault.

-MediaPath is the CPM installer ZIP itself, or a folder or CyberArk bundle ZIP that contains it; the newest matching package is used.

The command validates everything first and asks for confirmation. Only then it asks for what you did not pass: the Windows account of the server and the password of the Vault user Administrator. With -WhatIf nothing is asked and nothing is contacted. The installation runs in a detached controller process and keeps running when you close the console. The command returns the run id; follow the run with Wait-PASRun or Get-PASRun, or use -Wait.

Passwords are kept in memory only. PASeasyInstall builds labs. Production use is at your own risk.

| Parameter | Meaning |
|---|---|
| `-ComputerName` | IP address or DNS name of the server to install CPM on. |
| `-VaultAddress` | IP address or DNS name of the Vault the component registers with. |
| `-MediaPath` | The CPM installer ZIP, or a folder or CyberArk bundle ZIP that contains it. |
| `-Name` | Name of the environment (letters, digits, dot, dash, underscore). Runs are listed under it. Default: MyPAM. |
| `-Credential` | Local administrator of the server (or a domain account that is administrator there). Asked for when missing. The default account name is Administrator; to use another account pass it here. |
| `-VaultAdminPassword` | Password of the Vault user Administrator, used to register the component. Asked for when missing. |
| `-LabPassword` | One password for the server account and the Vault Administrator. Only with -SecurityProfile Lab. |
| `-SecurityProfile` | Secure (default): WinRM over HTTPS with a trusted certificate. Lab: accepts self-signed WinRM certificates. Every lab deviation is listed as a warning. Only the Lab profile was tested; Secure is not qualified. |
| `-Options` | Further recipe options as a hashtable. They are stored in the configuration (components[].options) and win over the defaults. Supported for CPM: installDirectory, cpmUser, vaultPort, registrationMode (Clean or Upgrade), hardeningScript. |
| `-PvwaCertificateFile` | Public certificate file (.cer, no private key) that CPM must trust to reach PVWA over HTTPS (options pvwaTrustCertificateFile and pvwaTrustCertificateSHA256; the SHA-256 is computed here). Secure profile: a self-signed CA certificate. Lab profile: the self-signed PVWA certificate itself is accepted too, as the audited deviation CPM.AllowPinnedLeafTrust. Leave it out when the server already trusts the PVWA certificate. |
| `-Wait` | Shows the progress until the run ends and returns the final run (see Wait-PASRun). |
| `-PlanOnly` | Validates the input and returns the plan. Asks nothing and contacts no server. |

```powershell
Install-PASCPM -ComputerName 192.0.2.22 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -Wait
```

Installs CPM. Asks for the server account and the Vault Administrator password, then shows the progress.

```powershell
$lab = Read-Host -AsSecureString 'Lab password'
Install-PASCPM -ComputerName 192.0.2.22 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -SecurityProfile Lab -LabPassword $lab -PvwaCertificateFile C:\Lab\pvwa01.cer
```

Lab install that pins the self-signed certificate of the lab PVWA. Returns the run id.

## Install-PASPSM

Installs the CyberArk Privileged Session Manager (PSM) on a Windows server and registers it with an existing Vault.

Uploads the installer, installs the prerequisites (Remote Desktop Session Host) and PSM, registers PSM with the Vault, applies the vendor hardening and verifies the result. The server restarts several times; the run continues by itself. Install PVWA first: the PSM registration needs the PVWA environment in the Vault.

-MediaPath is the PSM installer ZIP itself, or a folder or CyberArk bundle ZIP that contains it; the newest matching package is used.

The command validates everything first and asks for confirmation. Only then it asks for what you did not pass: the Windows account of the server and the password of the Vault user Administrator. With -WhatIf nothing is asked and nothing is contacted. The installation runs in a detached controller process and keeps running when you close the console. The command returns the run id; follow the run with Wait-PASRun or Get-PASRun, or use -Wait.

Passwords are kept in memory only. PASeasyInstall builds labs. Production use is at your own risk.

| Parameter | Meaning |
|---|---|
| `-ComputerName` | IP address or DNS name of the server to install PSM on. |
| `-VaultAddress` | IP address or DNS name of the Vault the component registers with. |
| `-MediaPath` | The PSM installer ZIP, or a folder or CyberArk bundle ZIP that contains it. |
| `-Name` | Name of the environment (letters, digits, dot, dash, underscore). Runs are listed under it. Default: MyPAM. |
| `-Credential` | Local administrator of the server (or a domain account that is administrator there). Asked for when missing. The default account name is Administrator; to use another account pass it here. |
| `-VaultAdminPassword` | Password of the Vault user Administrator, used to register the component. Asked for when missing. |
| `-LabPassword` | One password for the server account and the Vault Administrator. Only with -SecurityProfile Lab. |
| `-SecurityProfile` | Secure (default): WinRM over HTTPS with a trusted certificate. Lab: accepts self-signed WinRM certificates. Every lab deviation is listed as a warning. Only the Lab profile was tested; Secure is not qualified. |
| `-Options` | Further recipe options as a hashtable. They are stored in the configuration (components[].options) and win over the defaults. Supported for PSM: installDirectory, vaultPort. |
| `-Wait` | Shows the progress until the run ends and returns the final run (see Wait-PASRun). |
| `-PlanOnly` | Validates the input and returns the plan. Asks nothing and contacts no server. |

```powershell
Install-PASPSM -ComputerName 192.0.2.23 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -Wait
```

Installs PSM. Asks for the server account and the Vault Administrator password, then shows the progress.

```powershell
$lab = Read-Host -AsSecureString 'Lab password'
$id = Install-PASPSM -ComputerName 192.0.2.23 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia\PSM.zip -SecurityProfile Lab -LabPassword $lab
Wait-PASRun -RunId $id
```

Lab install from a renamed installer ZIP with one password; the run is followed afterwards.

## Install-PASPSMP

Installs the CyberArk PSM for SSH proxy (PSMP) on a Linux server and registers it with an existing Vault.

Signs in to the Linux server with SSH as root, uploads the installer package that matches the distribution of the server, installs and registers PSMP, applies the hardening and verifies the result. Install PVWA first: the PSMP registration needs the PVWA environment in the Vault.

SSH uses a key of this controller, kept under &lt;data folder&gt;\ssh\&lt;Name&gt;. On the first install the key is created and the root password is used once to authorise it on the server; the password is not stored. With the Lab profile the host key of the server is trusted on first use (logged as a deviation). With the Secure profile the host key must already be in the known_hosts file there.

-MediaPath is the PSMP installer ZIP itself, or a folder or CyberArk bundle ZIP that contains it; the newest matching package is used.

The command validates everything first and asks for confirmation. Only then it asks for what you did not pass: the root password of the server and the password of the Vault user Administrator. With -WhatIf nothing is asked and nothing is contacted. The installation runs in a detached controller process and keeps running when you close the console. The command returns the run id; follow the run with Wait-PASRun or Get-PASRun, or use -Wait.

Passwords are kept in memory only. PASeasyInstall builds labs. Production use is at your own risk.

| Parameter | Meaning |
|---|---|
| `-ComputerName` | IP address or DNS name of the server to install PSMP on. |
| `-VaultAddress` | IP address or DNS name of the Vault the component registers with. |
| `-MediaPath` | The PSMP installer ZIP, or a folder or CyberArk bundle ZIP that contains it. |
| `-Name` | Name of the environment (letters, digits, dot, dash, underscore). Runs are listed under it. Default: MyPAM. |
| `-Credential` | The root account of the Linux server and its password. Asked for when missing. PSMP is installed as root; another account is refused. |
| `-VaultAdminPassword` | Password of the Vault user Administrator, used to register the component. Asked for when missing. |
| `-LabPassword` | One password for the server account and the Vault Administrator. Only with -SecurityProfile Lab. |
| `-SecurityProfile` | Secure (default): the SSH host key of the server must already be known. Lab: the host key is trusted on first use. Every lab deviation is listed as a warning. Only the Lab profile was tested; Secure is not qualified. |
| `-Options` | Further recipe options as a hashtable. They are stored in the configuration (components[].options) and win over the defaults. Supported for PSMP: serverId, signingKeyFingerprint. |
| `-AcceptEula` | Confirms that you read and accept the CyberArk end user license agreement of the PSMP installer. Required: without it the configuration is not valid. |
| `-Wait` | Shows the progress until the run ends and returns the final run (see Wait-PASRun). |
| `-PlanOnly` | Validates the input and returns the plan. Asks nothing and contacts no server. |

```powershell
Install-PASPSMP -ComputerName 192.0.2.25 -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -AcceptEula -SecurityProfile Lab -Wait
```

Installs PSMP in a lab. Asks for the root password and the Vault Administrator password, then shows the progress.

```powershell
Install-PASPSMP -ComputerName psmp01.pam.lab -VaultAddress 192.0.2.11 -MediaPath D:\CyberArkMedia -AcceptEula -WhatIf
```

Validates the input and says what would be installed. Nothing is asked or contacted.

## Install-PASDomainController

Creates a new Active Directory forest for a lab on a Windows server (first domain controller).

Installs the AD DS role on -ComputerName, promotes the server to the first domain controller of a new forest named -DomainName, restarts it and verifies the domain. Use it to give a PAM lab its own directory; it is not meant to add a domain controller to an existing domain.

After the promotion the local Administrator of the server is the domain Administrator, with the same password.

The command validates everything first and asks for confirmation. Only then it asks for what you did not pass: the Windows account of the server and the Directory Services Restore Mode password. With -WhatIf nothing is asked and nothing is contacted. The installation runs in a detached controller process and keeps running when you close the console. The command returns the run id; follow the run with Wait-PASRun or Get-PASRun, or use -Wait.

Passwords are kept in memory only. PASeasyInstall builds labs. Production use is at your own risk.

| Parameter | Meaning |
|---|---|
| `-ComputerName` | IP address or DNS name of the Windows server that becomes the domain controller. |
| `-DomainName` | DNS name of the new forest root domain, e.g. pam.lab. |
| `-NetBiosName` | NetBIOS name of the domain. Default: the first label of -DomainName in upper case (PAM for pam.lab). |
| `-Name` | Name of the environment (letters, digits, dot, dash, underscore). Runs are listed under it. Default: MyPAM. |
| `-Credential` | Local administrator of the server. Asked for when missing. The default account name is Administrator; to use another account pass it here. |
| `-SafeModePassword` | Directory Services Restore Mode (DSRM) password to set. Asked for when missing. |
| `-LabPassword` | One password for the server account and the DSRM password. Only with -SecurityProfile Lab. |
| `-SecurityProfile` | Secure (default): WinRM over HTTPS with a trusted certificate. Lab: accepts self-signed WinRM certificates. Every lab deviation is listed as a warning. Only the Lab profile was tested; Secure is not qualified. |
| `-Wait` | Shows the progress until the run ends and returns the final run (see Wait-PASRun). |
| `-PlanOnly` | Validates the input and returns the plan. Asks nothing and contacts no server. |

```powershell
Install-PASDomainController -ComputerName 192.0.2.10 -DomainName pam.lab -Wait
```

Creates the forest pam.lab. Asks for the server account and the DSRM password, then shows the progress.

```powershell
$lab = Read-Host -AsSecureString 'Lab password'
Install-PASDomainController -ComputerName 192.0.2.10 -DomainName pam.lab -SecurityProfile Lab -LabPassword $lab
```

Lab install with one password. Returns the run id.
