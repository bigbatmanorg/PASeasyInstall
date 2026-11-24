# Portable ZIP

The portable release is the same module in a folder, with two launchers. Nothing is installed on the
controller and the controller needs no internet access. The window uses WPF, which is part of Windows, so no
runtime is bundled.

## Download and run

1. Download `PASeasyInstall-<version>-portable.zip` from
   [GitHub Releases](https://github.com/bigbatmanorg/PASeasyInstall/releases). A `SHA256SUMS` file lies next to it.
2. Unblock the ZIP **before** you extract it, so that Windows does not mark every file inside as downloaded:

    ```powershell
    Unblock-File -Path .\PASeasyInstall-*-portable.zip
    ```

    Or: right-click the ZIP, **Properties**, tick **Unblock**.

3. Extract it anywhere, for example to `C:\PASeasyInstall`.
4. Double-click **`Start-PASeasyInstall.cmd`**. The window opens.

```text
C:\PASeasyInstall\
  Start-PASeasyInstall.cmd / .ps1     the window (double-click the .cmd)
  PASeasyInstall-Shell.cmd / .ps1     a PowerShell window with every PASeasyInstall command loaded
  README-PORTABLE.txt, LICENSE.txt, THIRD_PARTY_*.txt
  PASeasyInstall\                     the module
```

The launchers clear the "downloaded from the internet" mark inside the folder, put the folder first on
`PSModulePath` for their own process only, and start Windows PowerShell 5.1 with
`-NoProfile -ExecutionPolicy Bypass`. They change nothing on the computer and need no administrator rights to
start. An execution policy set by Group Policy still applies (see [Execution policy](execution-policy.md)).

## Options of the launcher

```text
Start-PASeasyInstall.cmd -Backend Mock          the same window with a simulated installation
Start-PASeasyInstall.cmd -Config MyLab.json     opens a saved lab file
```

## The commands from the portable folder

Double-click `PASeasyInstall-Shell.cmd`. It opens a PowerShell window with every command of the
[command reference](../commands/index.md) loaded:

```powershell
(Get-PASLabPlan -Path C:\Labs\MyLab.json).Items | Format-Table Id, Type, Address, Media
Install-PASLab -Path C:\Labs\MyLab.json -Wait
```

## Updating

Download the newer ZIP and extract it to a new folder. Your lab files are separate JSON files, and the journals
of your installations are in `%LOCALAPPDATA%\PASeasyInstall`, so both carry over. Finish or give up a run that
stopped before you switch to the new folder: a run is never continued with changed scripts.

Next: [Your first lab](first-lab.md).
