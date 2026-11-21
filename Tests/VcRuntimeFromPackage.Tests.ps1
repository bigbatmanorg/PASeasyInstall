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
