# Save-PASEnvironment

Saves a validated configuration as JSON. Passwords are never part of it.

```powershell
Save-PASEnvironment -Configuration <object> -Path <file> [-Force]
```

It refuses to overwrite an existing file unless `-Force` is given, and writes atomically. The file can be checked
into your own lab repository and replayed with [`Invoke-PASeasyInstall`](invoke-paseasyinstall.md).

```powershell
Save-PASEnvironment -Configuration $cfg -Path C:\Labs\Lab01.json
```
