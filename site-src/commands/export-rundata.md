# Export-PASRunData

Writes a **sanitized ZIP** of one deployment (configuration, plan, status and event journals) for support, bug reports
or documentation.

```powershell
Export-PASRunData -RunId <32-character id> [-Path <file.zip>] [-Force]
```

- It accepts the ID returned by `Invoke-PASeasyInstall`, `Start-PASEnvironment` or the desktop: a single engine run,
  or a composed deployment together with its unit runs.
- Credential envelopes, lock files and generated payload scripts are never included.
- Every file is scanned for private keys, credential ciphers and password fields. A file with a hit is left out and
  listed in the result.
- The default path is `.\PASeasyInstall-run-<RunId>.zip`.

```powershell
Export-PASRunData -RunId 688d8e04f1874d41a75cda4441c00553
Export-PASRunData -RunId $id -Path C:\Temp\lab-run.zip -Force
```
