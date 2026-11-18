BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}
Describe 'Content-addressed and selective media extraction' {
    It 'does not reuse a role cache when bytes change but length and timestamp do not' {
        $path=Join-Path $TestDrive 'role.zip';[IO.File]::WriteAllText($path,'AAAA')
        $time=[IO.File]::GetLastWriteTimeUtc($path)
        $first=& (Get-Module PASeasyInstall.Core) {param($path) Get-PASCacheKey (Get-Item -LiteralPath $path) 'fixture'} $path
        [IO.File]::WriteAllText($path,'BBBB');[IO.File]::SetLastWriteTimeUtc($path,$time)
        $second=& (Get-Module PASeasyInstall.Core) {param($path) Get-PASCacheKey (Get-Item -LiteralPath $path) 'fixture'} $path
        $second | Should -Not -Be $first
    }
    It 'validates excluded archive paths before publishing any selective media' {
        $path=Join-Path $TestDrive 'malicious-bundle.zip';$dest=Join-Path $TestDrive 'selected'
        $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach($name in @('license.xml','../excluded.txt')){$entry=$zip.CreateEntry($name);$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write('fixture')}finally{$writer.Dispose()}}
        }finally{$zip.Dispose()}
        {& (Get-Module PASeasyInstall.Core) {param($path,$dest) Expand-PASMedia -SourcePath $path -Destination $dest -Include {param($name) $name -eq 'license.xml'}} $path $dest} | Should -Throw
        Test-Path $dest | Should -BeFalse
        Test-Path (Join-Path $TestDrive 'excluded.txt') | Should -BeFalse
    }
    It 'extracts only approved media while preserving entry prevalidation' {
        $path=Join-Path $TestDrive 'safe-bundle.zip';$dest=Join-Path $TestDrive 'safe-selected'
        $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
        try {foreach($name in @('license.xml','unselected.txt')){$entry=$zip.CreateEntry($name);$writer=[IO.StreamWriter]::new($entry.Open());try{$writer.Write('fixture')}finally{$writer.Dispose()}}}finally{$zip.Dispose()}
        & (Get-Module PASeasyInstall.Core) {param($path,$dest) Expand-PASMedia -SourcePath $path -Destination $dest -Include {param($name) $name -eq 'license.xml'}} $path $dest | Out-Null
        Test-Path (Join-Path $dest 'license.xml') | Should -BeTrue
        Test-Path (Join-Path $dest 'unselected.txt') | Should -BeFalse
    }
}
