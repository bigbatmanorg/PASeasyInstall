# The Vault lock (Private\Engine\Locks.ps1): a named mutex per Vault address on this controller.
# Mutex names in the Global\ namespace exist on Windows only.
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    $script:NotWindows = ($env:OS -ne 'Windows_NT')
    function New-TestVaultAddress {
        # A different documentation address per test, so tests never wait for each other.
        return ('vault-' + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.test')
    }
}

Describe 'Vault lock' {
    It 'is taken and released' -Skip:($env:OS -ne 'Windows_NT') {
        $address = New-TestVaultAddress
        InModuleScope PASeasyInstall -Parameters @{ Address = $address } {
            param($Address)
            $lock = Enter-PASVaultLock -Address $Address -TimeoutSeconds 5
            $lock | Should -BeOfType ([Threading.Mutex])
            { Exit-PASVaultLock $lock } | Should -Not -Throw
            # Free again: a new holder gets it at once.
            $again = Enter-PASVaultLock -Address $Address -TimeoutSeconds 1
            Exit-PASVaultLock $again
        }
    }
    It 'can be taken again by the thread that holds it (a step inside the Vault installation)' -Skip:($env:OS -ne 'Windows_NT') {
        $address = New-TestVaultAddress
        InModuleScope PASeasyInstall -Parameters @{ Address = $address } {
            param($Address)
            $outer = Enter-PASVaultLock -Address $Address -TimeoutSeconds 5
            try {
                $inner = Enter-PASVaultLock -Address $Address -TimeoutSeconds 1
                Exit-PASVaultLock $inner
            } finally {
                Exit-PASVaultLock $outer
            }
        }
    }
    It 'treats upper case and a trailing dot as the same Vault' -Skip:($env:OS -ne 'Windows_NT') {
        $address = New-TestVaultAddress
        $name = 'Global\PASeasyInstall-Vault-' + $address
        InModuleScope PASeasyInstall -Parameters @{ Address = $address; Name = $name } {
            param($Address, $Name)
            $lock = Enter-PASVaultLock -Address ($Address.ToUpperInvariant() + '.') -TimeoutSeconds 5
            try {
                $existing = $null
                [Threading.Mutex]::TryOpenExisting($Name, [ref]$existing) | Should -BeTrue
                if ($existing) { $existing.Dispose() }
            } finally {
                Exit-PASVaultLock $lock
            }
        }
    }
    It 'stops with a clear message while another holder has it, and works again afterwards' -Skip:($env:OS -ne 'Windows_NT') {
        $address = New-TestVaultAddress
        $name = 'Global\PASeasyInstall-Vault-' + $address
        $ready = New-Object Threading.ManualResetEvent($false)
        $release = New-Object Threading.ManualResetEvent($false)
        # Another thread of this process stands in for a second controller.
        $other = [powershell]::Create()
        [void]$other.AddScript({
                param($MutexName, $Ready, $Release)
                $mutex = New-Object Threading.Mutex($false, $MutexName)
                [void]$mutex.WaitOne()
                try {
                    [void]$Ready.Set()
                    [void]$Release.WaitOne(60000)
                } finally {
                    $mutex.ReleaseMutex()
                    $mutex.Dispose()
                }
            }).AddArgument($name).AddArgument($ready).AddArgument($release)
        $pending = $other.BeginInvoke()
        try {
            $ready.WaitOne(15000) | Should -BeTrue
            { InModuleScope PASeasyInstall -Parameters @{ Address = $address } { param($Address) Enter-PASVaultLock -Address $Address -TimeoutSeconds 1 } } |
                Should -Throw '*is in use by another PASeasyInstall controller*'
        } finally {
            [void]$release.Set()
            [void]$other.EndInvoke($pending)
            $other.Dispose()
            $ready.Dispose()
            $release.Dispose()
        }
        InModuleScope PASeasyInstall -Parameters @{ Address = $address } {
            param($Address)
            $lock = Enter-PASVaultLock -Address $Address -TimeoutSeconds 5
            Exit-PASVaultLock $lock
        }
    }
    It 'needs a Vault address' {
        { InModuleScope PASeasyInstall { Enter-PASVaultLock -Address ' ' } } | Should -Throw '*needs the Vault address*'
    }
    It 'ignores an empty lock on release' {
        { InModuleScope PASeasyInstall { Exit-PASVaultLock $null } } | Should -Not -Throw
    }
}
