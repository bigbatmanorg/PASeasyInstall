# Lab findings of 2026-11-24 (owner's run 9da236dc): a retry of the PSM hardening must not touch the finished
# servers; the PSM hardening may be repeated once when the vendor only timed out restarting LanmanServer; two
# media checks at the same time must not fail on files the other one wrote.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
}

Describe 'A continued parallel run starts only the lanes that did not finish' {
    It 'skips finished lanes and integrations before it starts any lane' {
        $source = Get-Content -LiteralPath (Get-PASTestModulePath 'Private/Run/Lanes.ps1') -Raw
        $body = $source.Substring($source.IndexOf('function Invoke-PASRunLanes'))
        $skip = $body.IndexOf('Test-PASLaneFinished -Lane')
        $start = $body.IndexOf('BeginInvoke()')
        $skip | Should -BeGreaterThan 0
        $skip | Should -BeLessThan $start
        $body.IndexOf('Test-PASIntegrationFinished') | Should -BeLessThan $start
    }
}

Describe 'PSM hardening that only timed out restarting LanmanServer' {
    BeforeAll {
        . (Get-PASTestModulePath 'Recipes/WindowsComponent/Psm.ps1')
        $script:savedProgramFiles = ${env:ProgramFiles(x86)}
        $script:logs = Join-Path $TestDrive 'pf/CyberArk/PSM/Hardening/Logs'
        New-Item -ItemType Directory -Path $script:logs -Force | Out-Null
        ${env:ProgramFiles(x86)} = Join-Path $TestDrive 'pf'
    }
    AfterAll {
        ${env:ProgramFiles(x86)} = $script:savedProgramFiles
    }
    BeforeEach {
        Get-ChildItem -LiteralPath $script:logs -File | Remove-Item -Force
    }
    It 'recognises a log whose only error is the LanmanServer restart timeout' {
        Set-Content -LiteralPath (Join-Path $script:logs 'PSMHardening-112426-162148.log') -Value @(
            '112426 162308 [2836]  Restarting service ''LanmanServer''.',
            '112426 162338 [2836]  Error restarting LanmanServer: Time out has expired and the operation has not been completed.',
            '112426 162338 [2836]  Admin share hardening completed successfully.')
        Test-PASeasyPsmLanmanRestartTimeout -Since (Get-Date).AddMinutes(-1) | Should -BeTrue
    }
    It 'does not retry when the log has another error as well' {
        Set-Content -LiteralPath (Join-Path $script:logs 'PSMHardening-112426-162148.log') -Value @(
            '112426 162338 [2836]  Error restarting LanmanServer: Time out has expired and the operation has not been completed.',
            '112426 162339 [2836]  Failed to set AppLocker rules')
        Test-PASeasyPsmLanmanRestartTimeout -Since (Get-Date).AddMinutes(-1) | Should -BeFalse
    }
    It 'does not retry without a hardening log of this attempt' {
        $old = Join-Path $script:logs 'PSMHardening-112426-100000.log'
        Set-Content -LiteralPath $old -Value 'Error restarting LanmanServer: Time out has expired'
        (Get-Item -LiteralPath $old).LastWriteTime = (Get-Date).AddHours(-2)
        Test-PASeasyPsmLanmanRestartTimeout -Since (Get-Date).AddMinutes(-1) | Should -BeFalse
    }
}

Describe 'Media files written by two checks at once' {
    It 'writes a ZIP entry over a file another check wrote already' {
        $zipPath = Join-Path $TestDrive 'one.zip'
        $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
        try {
            $entry = $zip.CreateEntry('a.txt')
            $writer = New-Object IO.StreamWriter($entry.Open())
            try { $writer.Write('content') } finally { $writer.Dispose() }
        } finally { $zip.Dispose() }
        $to = Join-Path $TestDrive 'a.txt'
        & (Get-Module PASeasyInstall) {
            param($zipPath, $to)
            foreach ($i in 1..2) {
                $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
                try { Save-PASZipEntry -Entry $zip.Entries[0] -Path $to } finally { $zip.Dispose() }
            }
        } $zipPath $to
        Get-Content -LiteralPath $to -Raw | Should -Be 'content'
        @(Get-ChildItem -LiteralPath $TestDrive -Filter '*.part').Count | Should -Be 0
    }
    It 'replaces a JSON file that appeared between the test and the move' {
        $path = Join-Path $TestDrive 'marker.json'
        & (Get-Module PASeasyInstall) {
            param($path)
            Write-PASJsonAtomic -Path $path -Data @{ n = 1 }
            Write-PASJsonAtomic -Path $path -Data @{ n = 2 }
        } $path
        (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).n | Should -Be 2
    }
}
