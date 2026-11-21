# Vault Server silent install (runs detached as SYSTEM). Mirrors the vendor role/oracle: response file from
# the vendor template, setup.exe /runfromtemp /clone_wait /w /s, setup.log ResultCode=0, dbparm RecoveryPrvKey.
param(
    [Parameter(Mandatory = $true)][hashtable]$Settings,
    [Parameter(Mandatory = $true)][string]$AdminPassword,
    [Parameter(Mandatory = $true)][string]$MasterPassword
)
$ErrorActionPreference = 'Stop'
foreach ($s in @($AdminPassword, $MasterPassword)) { if ($s -match '[\r\n]') { throw 'Newline in installer password cannot be written to ISS' } }
$folder = Join-Path $Settings.PackagesRoot 'Server'
$installer = Join-Path $folder 'setup.exe'
if (-not(Test-Path -LiteralPath $installer)) { throw 'Vault Server setup.exe not found' }
$template = Join-Path $Settings.AutomationRoot 'Templates\vault-iss.j2'
if (-not(Test-Path -LiteralPath $template)) { throw 'Vendor response template not staged' }
if (Get-Service -Name 'PrivateArk Server' -ErrorAction SilentlyContinue) { throw 'Vault Server already installed; refusing to rerun the installer' }
$iss = Join-Path $folder 'setup.iss'
if (Test-Path -LiteralPath $iss) { throw 'Pre-existing installer response file detected; refusing to overwrite an interrupted install' }
foreach ($req in @('license.xml', 'server.key', 'recpub.key', 'rndbase.dat')) { if (-not(Test-Path -LiteralPath (Join-Path $Settings.KeysDir $req))) { throw "Missing $req in Keys directory" } }
$contents = [IO.File]::ReadAllText($template)
$map = [ordered]@{
    '{{ vault_installation_path }}' = [string]$Settings.InstallRoot
    '{{ safes_data_drive }}' = [string]$Settings.DataDrive
    '{{ keys_folder }}' = [string]$Settings.KeysDir
    '{{ vault_master_password }}' = $MasterPassword
    '{{ vault_admin_password }}' = $AdminPassword
}
foreach ($k in $map.Keys) { $contents = $contents.Replace($k, $map[$k]) }
if ($contents -match '{{[^}]+}}') { throw 'Unresolved vendor installer template variables' }
New-Item -ItemType Directory -Force -Path (Join-Path $Settings.DataDrive 'PrivateArk\StagingArea') | Out-Null
try {
    [IO.File]::WriteAllText($iss, $contents, [Text.Encoding]::ASCII)
    $acl = & icacls.exe $iss /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Unable to protect installer response file' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $installer -ArgumentList '/runfromtemp /clone_wait /w /s' -WorkingDirectory $folder -Wait -PassThru
    # /clone_wait should cover the temp clone; still wait for any InstallShield process to finish (oracle lesson).
    $deadline = (Get-Date).AddMinutes(30)
    while ((Get-Process -Name setup, ISBEW64, IsUninst -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 10 }
    $log = Join-Path $folder 'setup.log'
    if (-not(Test-Path -LiteralPath $log)) { throw "InstallShield setup.log is missing (setup exit $($p.ExitCode))" }
    $result = Get-Content -LiteralPath $log | Where-Object { $_ -match '^ResultCode=' } | Select-Object -Last 1
    if ($result -notmatch '^ResultCode=0\s*$') { throw "Vault setup.log does not confirm success: $result (exit $($p.ExitCode))" }
} finally {
    # setup.iss contains plaintext Master/Administrator passwords; it never outlives the installer.
    Remove-Item -LiteralPath $iss -Force -ErrorAction SilentlyContinue
}
foreach ($l in @('127.0.0.1:5986', '[::1]:5986')) { & netsh.exe http delete iplisten "ipaddress=$l" 2>&1 | Out-Null }
$dbparm = Join-Path $Settings.InstallRoot 'Server\Conf\dbparm.ini'
$lines = @(Get-Content -LiteralPath $dbparm)
$want = 'RecoveryPrvKey=' + (Join-Path $Settings.KeysDir 'recprv.key')
if (-not ($lines -contains $want)) {
    $lines = @($lines | Where-Object { $_ -notmatch '^RecoveryPrvKey=' }) + $want
    Set-Content -LiteralPath $dbparm -Value $lines -Encoding Default
}
[pscustomobject]@{
    Changed = $true
    Message = ("Vault Server installed in {0:N0}s; setup.log ResultCode=0" -f $sw.Elapsed.TotalSeconds)
}
