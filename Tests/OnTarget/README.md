# Manual on-target checks

These scripts are not part of the Pester suite and CI does not run them.
Run them by hand on a disposable lab server (or, for `SecretLeakScan.ps1`, on the controller).

- `Linux*.Contract.sh` / `Linux*.Contract.py`: run as root on a throw-away Linux PSMP target.
  Each one states its requirements in its first lines. Some need `pwsh` and a copy of this repository.
- `SecretLeakScan.ps1`: run on the controller after a lab install. It searches the data root for one
  exact secret value and prints only file names and counts.

They check behaviour that mocks cannot prove (systemd, file ownership, package tools).
Never run them on a server you want to keep.
