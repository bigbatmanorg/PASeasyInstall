BeforeAll {
    $hostPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall/Private/Engine/Assets/TaskHost.ps1'
    Add-Type -AssemblyName System.Security
}
Describe 'Windows detached machine-bound inputs' {
    It 'decrypts ciphertext, redacts its secret, and deletes the input before returning' {
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item $directory -ItemType Directory | Out-Null
        $marker = 'EncryptedInputMarker-' + [guid]::NewGuid().ToString('N')
        'param($Password) [pscustomobject]@{Changed=$false;Message=$Password}' | Set-Content (Join-Path $directory 'task.ps1')
        $clear = [Text.Encoding]::UTF8.GetBytes((@{Password = $marker } | ConvertTo-Json))
        $cipher = [Security.Cryptography.ProtectedData]::Protect($clear, [Text.Encoding]::UTF8.GetBytes((Split-Path $directory -Leaf)), [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $path = Join-Path $directory 'inputs.dpapi'
        [IO.File]::WriteAllBytes($path, $cipher)
        [Text.Encoding]::UTF8.GetString($cipher) | Should -Not -Match $marker
        $result = & $hostPath -Directory $directory -DeleteInputs -RequireProtectedInputs
        $result.Ok | Should -BeTrue
        ($result | ConvertTo-Json -Depth 10) | Should -Not -Match $marker
        Test-Path $path | Should -BeFalse
        Test-Path (Join-Path $directory 'inputs.json') | Should -BeFalse
    }
    It 'fails closed on plaintext substitution without executing the task body' {
        $directory = Join-Path $TestDrive 'plaintext'
        New-Item $directory -ItemType Directory | Out-Null
        "throw 'TASK_BODY_MUST_NOT_RUN'" | Set-Content (Join-Path $directory 'task.ps1')
        '{"Password":"marker"}' | Set-Content (Join-Path $directory 'inputs.json')
        $result = & $hostPath -Directory $directory -DeleteInputs -RequireProtectedInputs
        $result.Ok | Should -BeFalse
        $result.Error | Should -Match 'refusing plaintext fallback'
        $result.Error | Should -Not -Match 'TASK_BODY_MUST_NOT_RUN'
    }
    It 'rejects another attempt entropy and removes the rejected encrypted input' {
        $directory = Join-Path $TestDrive 'wrong-attempt'
        New-Item $directory -ItemType Directory | Out-Null
        "throw 'TASK_BODY_MUST_NOT_RUN'" | Set-Content (Join-Path $directory 'task.ps1')
        $cipher = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes('{}'), [Text.Encoding]::UTF8.GetBytes('different-attempt'), [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $path = Join-Path $directory 'inputs.dpapi'
        [IO.File]::WriteAllBytes($path, $cipher)
        $result = & $hostPath -Directory $directory -DeleteInputs -RequireProtectedInputs
        $result.Ok | Should -BeFalse
        $result.Error | Should -Not -Match 'TASK_BODY_MUST_NOT_RUN'
        Test-Path $path | Should -BeFalse
    }
}
