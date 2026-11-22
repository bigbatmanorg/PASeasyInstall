# Portable ZIP

The portable release contains the PASeasyInstall module (the commands and the desktop). It needs nothing else:
the window is drawn with WPF, which is part of Windows. Unzip it and run it. Nothing is installed on the controller, and
the controller needs no internet access.

## Download and run

1. Download `PASeasyInstall-<version>-portable.zip` from the
   [GitHub Releases](https://github.com/bigbatmanorg/PASeasyInstall/releases) page.
2. Unblock the ZIP **before** extracting it, so Windows does not flag every file inside as downloaded:

    ```powershell
    Unblock-File -Path .\PASeasyInstall-2.0.0-portable.zip
    ```

3. Extract it, for example to `C:\PASeasyInstall`.
4. Double-click **`Start-PASeasyInstall.cmd`**. The desktop opens in a fresh Windows PowerShell 5.1 process
   that uses the modules bundled in the folder.

```text
C:\PASeasyInstall\
  Start-PASeasyInstall.cmd / .ps1     the desktop (double-click the .cmd)
  PASeasyInstall-Shell.cmd / .ps1     a PowerShell window with every PASeasyInstall command loaded
  README-PORTABLE.txt, LICENSE.txt, THIRD_PARTY_*.txt
  PASeasyInstall\                     the module: commands and desktop window
```

The launchers unblock the extracted files, put the folder first on `PSModulePath` for their own
process only, and start Windows PowerShell 5.1 with `-ExecutionPolicy Bypass`. A `SHA256SUMS` file is published next
to the ZIP on the release page.

## Command line from the portable folder

Double-click `PASeasyInstall-Shell.cmd` for a PowerShell window with every command from the
[command reference](../commands/index.md) loaded:

```powershell
(Get-PASLabPlan -Path C:\Labs\Lab01.json).Items | Format-Table Id, Type, Address, Media
Install-PASLab -Path C:\Labs\Lab01.json -Wait
Resume-PASRun -RunId <run id> -Wait
```

`Start-PASeasyInstall.cmd -Config C:\Labs\Lab01.json` reopens a saved project in the desktop.

## Updating

Download the newer ZIP and extract it to a new folder. Your projects are separate JSON files, and run journals live in
`%LOCALAPPDATA%\PASeasyInstall`, so they carry over.
