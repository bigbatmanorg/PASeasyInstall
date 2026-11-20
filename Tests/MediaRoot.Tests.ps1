# Regression: the composed Vault media folder must not be a parent that also contains other media trees
# (e.g. a second product version), or the Vault recipe finds the VC++ runtimes twice ("VCx86: Ambiguous").
BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $env:PAS_EASY_DATA_ROOT = Join-Path $TestDrive 'data'
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    . (Get-PASTestPrivateProxy)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    function New-TestZip([string]$Path, [string[]]$Entries) {
        $dir = [IO.Path]::GetDirectoryName($Path)
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory $dir -Force | Out-Null }
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Create)
        $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($e in $Entries) {
                $w = New-Object IO.StreamWriter($zip.CreateEntry($e).Open())
                $w.Write('synthetic ' + $e)
                $w.Dispose()
            }
        } finally {
            $zip.Dispose()
            $fs.Dispose()
        }
    }
    function New-MediaTree([string]$Root) {
        New-TestZip (Join-Path $Root 'CorePAS/Vault/Server-Rls-v15.0.zip') @('setup.exe')
        New-TestZip (Join-Path $Root 'CorePAS/Vault/PACLI-Rls-v15.0.zip') @('pacli.exe')
        New-TestZip (Join-Path $Root 'CorePAS/Vault/Disaster Recovery-Rls-v15.0.zip') @('setup.exe')
        [IO.File]::WriteAllText((Join-Path $Root 'license.xml'), '<license/>')
        [IO.File]::WriteAllText((Join-Path $Root 'VC_redist.x86.exe'), 'x86')
        [IO.File]::WriteAllText((Join-Path $Root 'VC_redist.x64.exe'), 'x64')
    }
    $script:top = Join-Path $TestDrive 'CyberArk'
    New-MediaTree (Join-Path $script:top 'install_media')
    New-MediaTree (Join-Path $script:top 'install_media_other_version')   # sibling tree with its own runtimes
    New-Item -ItemType Directory (Join-Path $script:top 'keys') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $script:top 'keys/recpub.key'), 'public')
    function New-Config([string[]]$Paths) {
        $sel = Get-PASMediaSelection -Inventory @(Get-PASMediaInventory -Path $Paths)
        New-PASDeploymentConfiguration -Environment MR -VaultMode PrimaryDR -Instances @() -ControllerAddress 192.0.2.10 `
            -PrimaryAddress 192.0.2.11 -DRAddress 192.0.2.12 -Media $sel -ExecutionMode Sequential -SecurityProfile Lab 3>$null
    }
}

Describe 'Composed Vault media folder' {
    It 'uses the media folder, not a parent shared with another media tree' {
        $c = New-Config @((Join-Path $script:top 'install_media'), (Join-Path $script:top 'keys/recpub.key'))
        [IO.Path]::GetFullPath([string]$c.mediaRoot) | Should -Be ([IO.Path]::GetFullPath((Join-Path $script:top 'install_media')))
        $c.media.PublicRecoveryKey | Should -Match 'recpub\.key$'
    }

    It 'refuses with a clear message when the media folder itself holds two runtimes' {
        $dup = Join-Path $TestDrive 'dup'
        New-MediaTree $dup
        New-Item -ItemType Directory (Join-Path $dup 'extra') -Force | Out-Null
        Copy-Item (Join-Path $dup 'VC_redist.x86.exe') (Join-Path $dup 'extra/VC_redist.x86.exe')
        { New-Config @($dup, (Join-Path $script:top 'keys/recpub.key')) } | Should -Throw '*Several copies of the VC++ runtime*'
    }
}
