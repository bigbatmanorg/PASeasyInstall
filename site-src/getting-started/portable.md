# Portable ZIP

The portable release contains PASeasyInstall **and** everything it needs to run: the NativeHTMLKit and
NativeHTMLKit.UI modules with their native window host. Unzip it and run it. Nothing is installed on the controller, and
the controller needs no internet access.

## Download and run

1. Download `PASeasyInstall-<version>-portable.zip` from the
   [GitHub Releases](https://github.com/bigbatmanorg/PASeasyInstall/releases) page.
2. Unblock the ZIP **before** extracting it, so Windows does not flag every file inside as downloaded:

    ```powershell
    Unblock-File -Path .\PASeasyInstall-1.0.0-portable.zip
    ```

3. Extract it, for example to `C:\PASeasyInstall`.
4. Double-click **`Start-PASeasyInstall.cmd`**. The desktop opens in a fresh Windows PowerShell 5.1 process
   that uses the modules bundled in the folder.

```text
C:\PASeasyInstall\
  Start-PASeasyInstall.cmd / .ps1     the desktop (double-click the .cmd)
  Invoke-PASeasyInstall.cmd / .ps1    command-line install from a saved project
  PASeasyInstall-Shell.cmd / .ps1     a PowerShell window with every PASeasyInstall command loaded
  README-PORTABLE.txt, LICENSE.txt, THIRD_PARTY_*.txt
  Modules\PASeasyInstall\<version>\  the module
  Modules\NativeHTMLKit.UI\, Modules\NativeHTMLKit\   the desktop runtime, including its native host
```

The launchers unblock the extracted files, put the bundled `Modules` folder first on `PSModulePath` for their own
process only, and start Windows PowerShell 5.1 with `-ExecutionPolicy Bypass`. A `SHA256SUMS` file is published next
to the ZIP on the release page.

## Command line from the portable folder

```bat
C:\PASeasyInstall\Invoke-PASeasyInstall.cmd -Config C:\Labs\Lab01.json -PlanOnly
C:\PASeasyInstall\Invoke-PASeasyInstall.cmd -Config C:\Labs\Lab01.json -Wait
C:\PASeasyInstall\Invoke-PASeasyInstall.cmd -Resume <runId> -RetryFailedPreflight
```

Or double-click `PASeasyInstall-Shell.cmd` for a PowerShell window with every command from the
[command reference](../commands/index.md) loaded.

## Updating

Download the newer ZIP and extract it to a new folder. Your projects are separate JSON files, and run journals live in
`%LOCALAPPDATA%\PASeasyInstall`, so they carry over.
