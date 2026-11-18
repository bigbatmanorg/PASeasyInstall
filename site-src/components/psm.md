# PSM

Installs PSM on a **workgroup** (out-of-domain) Windows Server. That is the vendor's supported non-domain path.

| Stage | What it does |
|---|---|
| `management`, `media-upload`, `preflight`, `extract` | As for PVWA; locates the vendor's `Execute-Stage.ps1` automation |
| `prerequisites` | Remote Desktop Session Host and other prerequisites. **Reboots** and continues the same stage. |
| `install` | Vendor installation, followed by a **reboot** and continuation |
| `register` | Registers PSM in the Vault |
| `harden` | CyberArk PSM hardening (legacy TLS off, TLS 1.2 on), followed by a **reboot** |
| `postinstall` | Vendor post-installation tasks |
| `verify` | The *CyberArk Privileged Session Manager* service runs |

Each vendor stage is run in passes until it reports that no further reboot is needed. Reboots happen **without**
writing a plaintext autologon password.

PSM restricts untrusted creation at the Windows Temp root to protect its TLS backup, and existing child
permissions are preserved. The [Review plan](../gui/review.md) step shows this as a warning.
