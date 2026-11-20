# Installs prerequisites from staged, Authenticode-verified Microsoft media (no internet dependency).
param([Parameter(Mandatory = $true)][hashtable]$Settings)
$ErrorActionPreference = 'Stop'
$base = Join-Path $Settings.AutomationRoot 'Prerequisites'
$items = @(
    @{
        Name = 'VC++ 2015-2022 x86'
        Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86'
        File = 'VC_redist.x86.exe'
        Args = @('/install', '/quiet', '/norestart')
    },
    @{
        Name = 'VC++ 2015-2022 x64'
        Key = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
        File = 'VC_redist.x64.exe'
        Args = @('/install', '/quiet', '/norestart')
    },
    # PAKeyGen from the vendor role links against the VC++ 2013 x86 runtime (as the role's own vcredist_x86.exe).
    @{
        Name = 'VC++ 2013 x86'
        Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\12.0\VC\Runtimes\x86'
        File = 'vcredist_x86.exe'
        Args = @('/install', '/quiet', '/norestart')
    }
)
$changed = $false
$reboot = $false
$log = @()
foreach ($item in $items) {
    $installed = $false
    if (Test-Path -LiteralPath $item.Key) { $installed = [int](Get-ItemProperty -LiteralPath $item.Key -Name Installed -ErrorAction SilentlyContinue).Installed -eq 1 }
    if ($installed) {
        $log += "$($item.Name) present"
        continue
    }
    $file = Join-Path $base $item.File
    if (-not(Test-Path -LiteralPath $file)) { throw "Missing staged prerequisite $file" }
    $sig = Get-AuthenticodeSignature -FilePath $file
    if ($sig.Status -ne 'Valid' -or
        $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw "Untrusted signature on $($item.File): $($sig.Status)" }
    $p = Start-Process -FilePath $file -ArgumentList $item.Args -Wait -PassThru
    if ($p.ExitCode -notin @(0, 1638, 3010)) { throw "$($item.Name) installer exit $($p.ExitCode)" }
    if ($p.ExitCode -eq 3010) { $reboot = $true }
    $changed = $true
    $log += "$($item.Name) installed (exit $($p.ExitCode))"
}
$release = [int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -Name Release -ErrorAction SilentlyContinue).Release
if ($release -lt 528040) { throw ".NET Framework 4.8 required (release $release); Windows Server 2022 includes it" }
[pscustomobject]@{Changed = $changed; Message = (($log -join '; ') + "; .NET release $release"); Data = @{RebootRequired = $reboot } }
