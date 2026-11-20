# Extracts the PAKeyGen binaries and InstallShield templates from YOUR licensed "Vault Ansible Role" ZIP
# into a private media folder. Nothing extracted here may be committed.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RoleZip,[Parameter(Mandatory=$true)][string]$OutDirectory)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$OutDirectory=[IO.Path]::GetFullPath($OutDirectory)
$map=@{
    'templates/vault-iss.j2'='templates\vault-iss.j2'
    'templates/vaultdr-iss.j2'='templates\vaultdr-iss.j2'
    'files/InstallationAutomation/PAKeyGen/PAKeyGen.exe'='PAKeyGen\PAKeyGen.exe'
    'files/InstallationAutomation/PAKeyGen/calibeay32102o.dll'='PAKeyGen\calibeay32102o.dll'
    'files/InstallationAutomation/PAKeyGen/cassleay32102o.dll'='PAKeyGen\cassleay32102o.dll'
    'files/InstallationAutomation/Binaries/vcredist_x86.exe'='vcredist_x86.exe'
}
$archive=[IO.Compression.ZipFile]::OpenRead(([IO.Path]::GetFullPath($RoleZip)))
try {
    foreach($name in $map.Keys){
        $found=@($archive.Entries|Where-Object {$_.FullName.Replace('\','/').EndsWith($name,[StringComparison]::OrdinalIgnoreCase)})
        if($found.Count -ne 1){throw "Expected exactly one archive entry ending '$name'; found $($found.Count)"}
        $path=Join-Path $OutDirectory $map[$name]
        $dir=Split-Path -Parent $path;if(-not(Test-Path $dir)){New-Item -ItemType Directory -Force -Path $dir|Out-Null}
        [IO.Compression.ZipFileExtensions]::ExtractToFile($found[0],$path,$true)
        Write-Output $path
    }
} finally {$archive.Dispose()}
