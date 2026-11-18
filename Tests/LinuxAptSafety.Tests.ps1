# The Linux recipe must never upgrade installed OS packages or let needrestart restart its own attempt
# units: a libc6 upgrade during PSMP prerequisites made needrestart kill the running attempt (exit 143).
BeforeAll { $script:task = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/Recipes/LinuxComponent/Task.sh') -Raw }

Describe 'Linux recipe package installs' {
    It 'never runs apt-get install without --no-upgrade and NEEDRESTART_SUSPEND' {
        $lines = @($script:task -split "`n" | Where-Object { $_ -match 'apt-get\s.*\binstall\b' -and $_ -notmatch '^\s*#' })
        $lines.Count | Should -BeGreaterThan 1
        foreach ($l in $lines) { $l | Should -Match '--no-upgrade'; $l | Should -Match 'NEEDRESTART_SUSPEND=1' }
    }
    It 'exempts its attempt units from needrestart before installing anything' {
        $script:task | Should -Match ([regex]::Escape('$nrconf{override_rc}{qr(^paeasy-.*)} = 0;'))
        $first = $script:task.IndexOf('paeasy_needrestart_guard', $script:task.IndexOf('  Preflight)'))
        $apt = $script:task.IndexOf('apt-get', $script:task.IndexOf('  Preflight)'))
        $first | Should -BeGreaterThan 0
        $first | Should -BeLessThan $apt
    }
}

Describe 'PSMP reinstall into an existing Vault' {
    It 'asks the vendor setup to recreate credential files of PSMP users that already exist' {
        $parms = @($script:task -split "`n" | Where-Object { $_ -match "printf .*AcceptCyberArkEULA=Yes.*> /var/tmp/psmpparms" })
        $parms.Count | Should -Be 2
        foreach ($p in $parms) { $p | Should -Match 'UpdateCredFile=Yes'; $p | Should -Match 'ADBridgeUpdateCredFile=Yes' }
    }
}

Describe 'PSMP on RHEL-family servers' {
    It 'verifies the RPM against the reviewed CyberArk signing key when no fingerprint is configured' {
        $script:task | Should -Match '\[\[ -n \$fingerprint \]\] \|\| fingerprint=97A2859B95D5F078AFC87C64A83D2D8A08BEAA44'
        $script:task | Should -Match 'rpm --checksig'
        $script:task | Should -Match "PSMP signing key fingerprint mismatch"
    }
}
