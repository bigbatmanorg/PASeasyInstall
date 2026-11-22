# The VC++ 2015-2022 runtimes the Vault needs are not shipped with the Vault, but inside the CPM, PVWA
# and PSM packages. Synthetic media in TestDrive; nothing is installed.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    function New-TestZip([string]$Path, [hashtable]$Entries) {
        $directory = [IO.Path]::GetDirectoryName($Path)
        if (-not (Test-Path $directory)) {
            New-Item -ItemType Directory $directory -Force | Out-Null
        }
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Create)
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $Entries.Keys) {
                $writer = New-Object IO.StreamWriter($zip.CreateEntry($name).Open())
                $writer.Write([string]$Entries[$name])
                $writer.Dispose()
            }
        } finally {
            $zip.Dispose()
            $stream.Dispose()
        }
    }
    function Resolve-TestMedia([string]$Folder) {
        $dataRoot = Join-Path $TestDrive ('data-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        & (Get-Module -Name PASeasyInstall) {
            param($folder, $dataRoot)
            $mediaProfile = [pscustomobject]@{ Mode = 'Primary'; MediaPath = $folder; MediaOverrides = @{} }
            Resolve-PASMediaProfile -Profile $mediaProfile -DataRoot $dataRoot
        } $Folder $dataRoot
    }
}

Describe 'VC++ runtimes from a component package' {
    It 'takes both runtimes from the CPM package when they are not in the media folder' {
        $media = Join-Path $TestDrive 'cpm'
        New-TestZip (Join-Path $media 'Central Policy Manager-Rls-v15.2.3.zip') @{
            'ISSetupPrerequisites/{789429B1}/VC_redist.x64.exe' = 'runtime x64 from CPM'
            'ISSetupPrerequisites/{AC341A78}/VC_redist.x86.exe' = 'runtime x86 from CPM'
            'InstallationAutomation/readme.txt' = 'x'
        }
        $resolved = Resolve-TestMedia $media
        [IO.Path]::GetFileName($resolved.MediaOverrides.VCx64) | Should -Be 'VC_redist.x64.exe'
        Get-Content -LiteralPath $resolved.MediaOverrides.VCx64 -Raw | Should -Be 'runtime x64 from CPM'
        Get-Content -LiteralPath $resolved.MediaOverrides.VCx86 -Raw | Should -Be 'runtime x86 from CPM'
    }
    It 'accepts the PVWA file names and prefers CPM over PVWA' {
        $media = Join-Path $TestDrive 'pvwa'
        New-TestZip (Join-Path $media 'Password Vault Web Access-Rls-v15.2.3.zip') @{
            'ISSetupPrerequisites/{1}/vcredist_x64.exe' = 'x64 from PVWA'
            'ISSetupPrerequisites/{2}/vcredist_x86.exe' = 'x86 from PVWA'
        }
        $resolved = Resolve-TestMedia $media
        Get-Content -LiteralPath $resolved.MediaOverrides.VCx64 -Raw | Should -Be 'x64 from PVWA'
        New-TestZip (Join-Path $media 'Central Policy Manager-Rls-v15.2.3.zip') @{
            'ISSetupPrerequisites/{1}/VC_redist.x64.exe' = 'x64 from CPM'
            'ISSetupPrerequisites/{2}/VC_redist.x86.exe' = 'x86 from CPM'
        }
        $resolved = Resolve-TestMedia $media
        Get-Content -LiteralPath $resolved.MediaOverrides.VCx64 -Raw | Should -Be 'x64 from CPM'
    }
    It 'leaves files in the media folder alone and asks for the runtimes when no package has them' {
        $media = Join-Path $TestDrive 'loose'
        New-TestZip (Join-Path $media 'Central Policy Manager-Rls-v15.2.3.zip') @{
            'ISSetupPrerequisites/{1}/VC_redist.x64.exe' = 'x64 from CPM'
            'ISSetupPrerequisites/{2}/VC_redist.x86.exe' = 'x86 from CPM'
        }
        [IO.File]::WriteAllText((Join-Path $media 'VC_redist.x64.exe'), 'loose x64')
        $resolved = Resolve-TestMedia $media
        $resolved.MediaOverrides.ContainsKey('VCx64') | Should -BeFalse
        Get-Content -LiteralPath $resolved.MediaOverrides.VCx86 -Raw | Should -Be 'x86 from CPM'

        $empty = Join-Path $TestDrive 'none'
        New-TestZip (Join-Path $empty 'Server-Rls-v15.2.zip') @{ 'setup.exe' = 'x' }
        $resolved = Resolve-TestMedia $empty
        $resolved.MediaOverrides.ContainsKey('VCx64') | Should -BeFalse
    }
}

Describe 'VC++ runtimes for a Vault that is installed on its own' {
    It 'takes them from a package of the media selection that is not installed (here: CPM inside the bundle)' {
        $saved = $env:PAS_EASY_DATA_ROOT
        $env:PAS_EASY_DATA_ROOT = Join-Path $TestDrive 'alone-data'
        try {
            $media = Join-Path $TestDrive 'alone'
            New-TestZip (Join-Path $media 'Server-Rls-v15.2.zip') @{ 'setup.exe' = 'x' }
            New-TestZip (Join-Path $media 'PACLI-Rls-v15.2.zip') @{ 'pacli.exe' = 'x' }
            $inner = Join-Path $TestDrive 'Central Policy Manager-Rls-v15.2.3.zip'
            New-TestZip $inner @{
                'ISSetupPrerequisites/{1}/VC_redist.x64.exe' = 'x64 from the bundled CPM'
                'ISSetupPrerequisites/{2}/VC_redist.x86.exe' = 'x86 from the bundled CPM'
            }
            $bundle = [IO.Compression.ZipFile]::Open((Join-Path $media 'Privileged Access Manager Self-Hosted-15.2.zip'), [IO.Compression.ZipArchiveMode]::Create)
            try {
                $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($bundle, $inner, 'Central Policy Manager (CPM)/Central Policy Manager-Rls-v15.2.3.zip')
            } finally {
                $bundle.Dispose()
            }
            $selection = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path $media)
            $selection.ContainsKey('CPM') | Should -BeTrue

            $alone = New-PASLabConfiguration -Environment Alone -VaultMode Primary -PrimaryAddress 192.0.2.11 -ControllerAddress 192.0.2.10 -Media $selection -SecurityProfile Lab
            [IO.Path]::GetFileName([string]$alone.options.vcRuntimePackage) | Should -Be 'Central Policy Manager-Rls-v15.2.3.zip'
            $rows = @(& (Get-Module -Name PASeasyInstall) { param($c) Get-PASVaultMediaStatus -Configuration $c } $alone)
            @($rows | Where-Object { $_.Key -in @('VCx86', 'VCx64') -and $_.Status -eq 'Ready' }).Count | Should -Be 2

            # With a PVWA in the lab its package brings the runtimes: nothing extra is noted.
            New-TestZip (Join-Path $media 'Password Vault Web Access-Rls-v15.2.3.zip') @{ 'x' = 'x' }
            $selection = Get-PASMediaSelection -Inventory (Get-PASMediaInventory -Path $media)
            $withPvwa = New-PASLabConfiguration -Environment Alone -VaultMode Primary -PrimaryAddress 192.0.2.11 -ControllerAddress 192.0.2.10 -Media $selection -SecurityProfile Lab `
                -Instances @(@{ Type = 'PVWA'; Name = 'PVWA01'; Address = '192.0.2.21' })
            $withPvwa.options.Contains('vcRuntimePackage') | Should -BeFalse
        } finally {
            $env:PAS_EASY_DATA_ROOT = $saved
        }
    }
}
