# Test-PASEnvironment

Validates a configuration: references, addresses, accounts, profile rules and, with `-CheckMedia`, that the media
exists and matches. It contacts no server.

```powershell
Test-PASEnvironment [-Config <path>] [-Configuration <object>] [-CheckMedia]
```

Returns `Valid`, `Issues` (blocking) and `Warnings` (including every security deviation).

```powershell
PS> Test-PASEnvironment -Config C:\Labs\Lab01-vault.json -CheckMedia | Format-List

Valid    : True
Issues   : {}
Warnings : {SECURITY DEVIATION: WinRM.SkipCNCheck = True, SECURITY DEVIATION: WinRM.SkipCACheck = True, SECURITY DEVIATION: Vault.AllowRDP = True}
```

Anything that cannot run is refused before it is dispatched to a server. For example, starting a Vault
installation whose media folder lacks the VC++ x86 runtime stops immediately with `Vault media VCx86: Missing`.
