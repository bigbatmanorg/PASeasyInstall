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

Observed in the reference lab, as the Vault reported it:

```text
Component         User              Address     LoggedOn Version
---------         ----              -------     -------- -------
PVWA              PVWAAppUser       10.10.0.21  True     15.0.0.58
CPM               PasswordManager   10.10.0.22  True     15.0.0.58
SessionManagement PSMApp_PAS-PSM    10.10.0.23  True     15.0.0.58
SessionManagement PSMPApp_PAS-PSMP  10.10.0.31  True     15.0.0.0
```

<!-- TODO(parent): replace with real captured Test-PASEnvironmentHealth output (the values above are from the lab
     health check script, reformatted to the command's Components columns). -->

A component that is installed but **not** logged on usually means its server is stopped, it cannot reach the Vault,
or the Vault restarted underneath it. See [Troubleshooting](../troubleshooting/index.md).
