# Get-PASStageCatalog

Lists a component's stages in order.

```powershell
Get-PASStageCatalog -Component Vault|DR|PVWA|CPM|PSM|PSMP|AD
```

```powershell
PS> Get-PASStageCatalog -Component PVWA | Format-Table Component,Stage,ReadOnly

Component Stage          ReadOnly
--------- -----          --------
PVWA      LocalPreflight     True
PVWA      management        False
PVWA      media-upload      False
PVWA      preflight         False
PVWA      extract           False
PVWA      prerequisites     False
PVWA      install           False
PVWA      configuretls      False
PVWA      register          False
PVWA      harden            False
PVWA      verify            False
```

The stages of every component are described under [Components](../components/index.md).
