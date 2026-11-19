# Test-PASEnvironmentHealth

Checks that an installed lab works. It opens **one** authenticated PVWA REST session with the Vault Administrator
credential, always logs off, and checks:

- **The PVWA API answers over HTTPS.** The certificate is validated normally, or pinned when `-PvwaCertificateFile`
  is given or the configuration's CPM pins one (a self-signed lab PVWA). The host name must still match.
- **Which components the Vault reports as logged on:** PVWA, CPM, PSM and PSMP.
- **PVWA maintenance mode.** The message `PASWS383E Vault is currently under maintenance mode` is detected.
- **DR replication.** With `-DRCredential`, the DR server's last PADR replication cycle is checked.

The session is serialised with deployments through the same Vault gate the installer uses.

```powershell
Test-PASEnvironmentHealth [-Config <path>] [-Configuration <object>] -VaultCredential <PSCredential>
    [-ApiBaseUri <uri>] [-PvwaCertificateFile <path.cer>] [-DRCredential <PSCredential>]
    [-TimeoutSeconds <10-600>] [-DRMaxAgeMinutes <5-1440>]
```

The result has `Healthy`, `ApiBaseUri`, `PvwaLogin`, `TlsValidation`, `Components` (component, user, address,
logged on, version), `Summary`, `DR`, `Issues` and `Message`.

```powershell
$h = Test-PASEnvironmentHealth -Config C:\Labs\Lab01.json -VaultCredential (Get-Credential Administrator) `
        -DRCredential (Get-Credential .\Administrator)
$h.Components | Format-Table Component,User,Address,LoggedOn,Version
```

Captured with 1.0 on a PAM 15.2 lab (addresses replaced). Both PSMP servers had been shut down, which is what
"not logged on" looks like:

```text
PS> $h.Healthy; $h.TlsValidation; $h.Issues
False
PinnedCertificate+HostName
SessionManagement PSMPApp_LB-PSMP (10.10.0.31) is not logged on to the Vault
SessionManagement PSMPApp_LB-PSMP2 (10.10.0.32) is not logged on to the Vault

PS> $h.Components | Format-Table Component,User,Address,LoggedOn,Version

Component         User             Address     LoggedOn Version
---------         ----             -------     -------- -------
PVWA              PVWAAppUser      10.10.0.21      True 15.2.4.115
CPM               PasswordManager  10.10.0.21      True 15.2.4.115
SessionManagement PSMApp_LB-PSM    10.10.0.23      True 15.2.4.115
SessionManagement PSMPApp_LB-PSMP  10.10.0.31     False 15.2.4.0
SessionManagement PSMPApp_LB-PSMP2 10.10.0.32     False 15.2.4.0
```

The PVWA certificate is pinned automatically when the deployment captured it for CPM at install time (desktop and
composed labs), or from `-PvwaCertificateFile`.

A component that is installed but **not** logged on usually means its server is stopped, it cannot reach the Vault,
or the Vault restarted underneath it. See [Troubleshooting](../troubleshooting/index.md).
