# PASeasyInstall is not Authenticode-signed (release decision). Every PowerShell process the toolkit starts, on the
# controller or on a target, must pass -ExecutionPolicy Bypass so it also runs where the local policy is AllSigned.
# A user's process-scoped Bypass does not reach processes started through Win32_Process.Create or a scheduled task.
BeforeAll {
    $root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1'); Import-PASTestModule
    $script:IsWindowsDesktop = ($env:OS -eq 'Windows_NT')
}

Describe 'Execution policy on every toolkit-started PowerShell process' {
    It 'passes -ExecutionPolicy Bypass on every launch line in the modules' {
        $files = @('PASeasyInstall','PASeasyInstall.UI') | ForEach-Object { Get-ChildItem -Path (Join-Path $root $_) -Recurse -File -Include '*.ps1','*.psm1' }
        $launches = @($files | Select-String -Pattern '-NoProfile -NonInteractive' -SimpleMatch)
        $launches.Count | Should -BeGreaterThan 4
        $missing = @($launches | Where-Object { $_.Line -notmatch '-ExecutionPolicy Bypass' } |
            ForEach-Object { '{0}:{1}' -f $_.Path, $_.LineNumber })
        $missing | Should -BeNullOrEmpty
    }

    It 'covers the controller start and resume, target task, recovery and AD reboot launches' {
        $expect = @{
            'PASeasyInstall/Private/Run/Run.ps1'                           = 2
            'PASeasyInstall/Private/Engine/Detached.ps1'                  = 1
            'PASeasyInstall/Private/Engine/Assets/WindowsDetachedRunner.ps1' = 1
            'PASeasyInstall/Recipes/ActiveDirectory/AD-Task.ps1'            = 1
        }
        foreach ($rel in $expect.Keys) {
            $hits = @(Select-String -Path (Join-Path $root $rel) -Pattern '-NonInteractive -ExecutionPolicy Bypass' -SimpleMatch)
            $hits.Count | Should -Be $expect[$rel] -Because $rel
        }
    }

    It 'generates detached target launch arguments with Bypass for runner and recovery entries' {
        $hashes = @{ 'runner.ps1' = ('A' * 64); 'recovery.ps1' = ('B' * 64) }
        $dir = 'C:\ProgramData\PAExec\attempts\0123456789abcdef0123456789abcdef'
        foreach ($entry in 'runner.ps1','recovery.ps1') {
            $arguments = & (Get-Module PASeasyInstall) { param($d, $h, $e) New-PASDetachedLaunchArguments -Directory $d -ExpectedHashes $h -Entry $e } $dir $hashes $entry
            $arguments | Should -Match '^-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "'
            $arguments | Should -Match ([regex]::Escape($entry))
        }
    }
}

Describe 'Bypass overrides an AllSigned process policy for an unsigned script' {
    It 'refuses the unsigned script without Bypass and runs it with Bypass' -Skip:(-not ($env:OS -eq 'Windows_NT')) {
        $script = Join-Path $TestDrive 'unsigned.ps1'
        [IO.File]::WriteAllText($script, "'unsigned-ran'")
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        function Invoke-Child([string]$Arguments) {
            $start = [Diagnostics.ProcessStartInfo]::new($exe, $Arguments)
            $start.UseShellExecute = $false; $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
            $start.EnvironmentVariables['PSExecutionPolicyPreference'] = 'AllSigned'   # simulates an AllSigned host
            $p = [Diagnostics.Process]::Start($start)
            $out = $p.StandardOutput.ReadToEnd(); [void]$p.StandardError.ReadToEnd()
            if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'child did not exit' }
            return $out
        }
        (Invoke-Child ('-NoProfile -NonInteractive -File "' + $script + '"')) | Should -Not -Match 'unsigned-ran'
        (Invoke-Child ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script + '"')) | Should -Match 'unsigned-ran'
    }
}
