BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/Recipes/WindowsComponent/Archive.ps1')
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    function New-ZipFixture($Path,$Entries) {
        $zip=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach($item in $Entries){
                $entry=$zip.CreateEntry([string]$item.Name)
                if($item.ContainsKey('Mode')){$entry.ExternalAttributes=([int]$item.Mode -shl 16)}
                $stream=$entry.Open()
                try{$bytes=[Text.Encoding]::UTF8.GetBytes([string]$item.Body);$stream.Write($bytes,0,$bytes.Length)}finally{$stream.Dispose()}
            }
        }finally{$zip.Dispose()}
    }
}
Describe 'Atomic component archive validation' {
    BeforeEach {$zipPath=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.zip');$dest=Join-Path $TestDrive ('payload-'+[guid]::NewGuid().ToString('N'))}
    It 'extracts nested files only after complete validation' {
        New-ZipFixture $zipPath @(@{Name='sub/';Body=''},@{Name='sub/script.ps1';Body='fixture'})
        Expand-PASeasyComponentArchive $zipPath $dest | Should -BeExactly $dest
        Get-Content (Join-Path $dest 'sub/script.ps1') | Should -BeExactly 'fixture'
    }
    It 'rejects unsafe names before creating the destination' -TestCases @(
        @{Name='../escape.txt'},@{Name='C:/escape.txt'},@{Name='//server/share/file'},
        @{Name='safe/file:secret'},@{Name='NUL.txt'},@{Name='safe/trailing.'},@{Name='safe/../escape'}
    ) {
        param($Name)
        New-ZipFixture $zipPath @(@{Name='first.txt';Body='safe'},@{Name=$Name;Body='bad'})
        {Expand-PASeasyComponentArchive $zipPath $dest} | Should -Throw
        Test-Path $dest | Should -BeFalse
    }
    It 'rejects case aliases and file-directory shadows' -TestCases @(
        @{Names=@('same.txt','SAME.txt')},@{Names=@('parent','parent/child.txt')}
    ) {
        param($Names)
        New-ZipFixture $zipPath @(@{Name=$Names[0];Body='a'},@{Name=$Names[1];Body='b'})
        {Expand-PASeasyComponentArchive $zipPath $dest} | Should -Throw
        Test-Path $dest | Should -BeFalse
    }
    It 'rejects links and special files' -TestCases @(@{Mode=40960},@{Mode=4096}) {
        param($Mode)
        New-ZipFixture $zipPath @(@{Name='link';Body='target';Mode=$Mode})
        {Expand-PASeasyComponentArchive $zipPath $dest} | Should -Throw
        Test-Path $dest | Should -BeFalse
    }
    It 'bounds expanded size and entry count before writing' {
        New-ZipFixture $zipPath @(@{Name='one';Body=('x'*30)},@{Name='two';Body='b'})
        {Expand-PASeasyComponentArchive $zipPath $dest -MaxBytes 10} | Should -Throw
        {Expand-PASeasyComponentArchive $zipPath $dest -MaxFiles 1} | Should -Throw
        Test-Path $dest | Should -BeFalse
    }
    It 'refuses to overwrite an existing destination' {
        New-ZipFixture $zipPath @(@{Name='one';Body='a'})
        New-Item $dest -ItemType Directory|Out-Null;Set-Content (Join-Path $dest 'preserve') 'original'
        {Expand-PASeasyComponentArchive $zipPath $dest} | Should -Throw
        Get-Content (Join-Path $dest 'preserve') | Should -BeExactly 'original'
    }
}
