# PSMP packages are per distribution. The deployment carries one selected package; once SSH works, the
# controller must use the package for the server's OS (a Rocky 9 server was sent the Ubuntu .deb package).
BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Orchestrator/PASeasyInstall.Orchestrator.psd1') -Force
    $script:host9 = @{ address = '192.0.2.46'; user = 'root'; identityFile = 'k'; knownHostsFile = 'kh' }
}
Describe 'PSMP package for the server distribution' {
    It 'maps os-release to the vendor variant' {
        InModuleScope PASeasyInstall.Orchestrator {
            Get-PASPsmpVariantForOs 'ubuntu' '24.04' 'debian' | Should -Be 'Ubuntu24'
            Get-PASPsmpVariantForOs 'rocky' '9.8' 'rhel centos fedora' | Should -Be 'RHELinux9'
            Get-PASPsmpVariantForOs 'almalinux' '8.10' 'rhel centos fedora' | Should -Be 'RHELinux8'
            Get-PASPsmpVariantForOs 'rhel' '9.4' 'fedora' | Should -Be 'RHELinux9'
            Get-PASPsmpVariantForOs 'debian' '12' '' | Should -Be ''
        }
    }
    It 'switches to the matching package from the same folder' {
        $dir = Join-Path $TestDrive 'plain'; New-Item -ItemType Directory $dir | Out-Null
        $u = Join-Path $dir 'PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.2.1.zip'; $r = Join-Path $dir 'PrivilegedSessionManagerSSHProxy-RHELinux9-Intel64-Rls-v15.2.1.zip'
        Set-Content $u 'u'; Set-Content $r 'r'
        InModuleScope PASeasyInstall.Orchestrator -Parameters @{ U = $u; R = $r; H = $script:host9 } {
            param($U, $R, $H)
            Mock Invoke-PASNativeQuiet { [pscustomobject]@{ ExitCode = 0; Output = 'rocky|9.8|rhel centos fedora|Rocky Linux 9.8 (Blue Onyx)' } }
            Mock Write-PASFleetEvent {}
            $c = @{ id = 'psmp'; type = 'PSMP'; media = $U; mediaSource = @{ path = $U; entry = '' } }
            Select-PASPsmpMediaForHost -Component $c -HostRecord $H -Directory 'x' -DataRoot $TestDrive
            $c.media | Should -Be $R
            Should -Invoke Write-PASFleetEvent -Times 1 -ParameterFilter { $Message -like '*RHELinux9*Rocky Linux 9.8*' }
        }
    }
    It 'switches to the matching package inside the same bundle' {
        $bundle = Join-Path $TestDrive 'PAM-15.2.zip'
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::Open($bundle, 'Create')
        foreach ($n in 'PSMP/PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.2.1.zip', 'PSMP/PrivilegedSessionManagerSSHProxy-RHELinux9-Intel64-Rls-v15.2.1.zip') {
            $w = New-Object IO.StreamWriter ($z.CreateEntry($n).Open()); $w.Write($n); $w.Dispose()
        }
        $z.Dispose()
        InModuleScope PASeasyInstall.Orchestrator -Parameters @{ B = $bundle; H = $script:host9 } {
            param($B, $H)
            Mock Invoke-PASNativeQuiet { [pscustomobject]@{ ExitCode = 0; Output = 'rocky|9.8|rhel centos fedora|Rocky Linux 9.8' } }
            Mock Write-PASFleetEvent {}
            $c = @{ id = 'psmp'; type = 'PSMP'; media = 'C:\cache\PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.2.1.zip'
                mediaSource = @{ path = $B; entry = 'PSMP/PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.2.1.zip' } }
            Select-PASPsmpMediaForHost -Component $c -HostRecord $H -Directory 'x' -DataRoot $TestDrive
            [IO.Path]::GetFileName($c.media) | Should -Be 'PrivilegedSessionManagerSSHProxy-RHELinux9-Intel64-Rls-v15.2.1.zip'
            Test-Path -LiteralPath $c.media | Should -BeTrue
        }
    }
    It 'keeps a package that already matches and stops clearly when none matches' {
        InModuleScope PASeasyInstall.Orchestrator -Parameters @{ H = $script:host9; D = $TestDrive } {
            param($H, $D)
            Mock Write-PASFleetEvent {}
            Mock Invoke-PASNativeQuiet { [pscustomobject]@{ ExitCode = 0; Output = 'ubuntu|24.04|debian|Ubuntu 24.04' } }
            $c = @{ id = 'psmp'; type = 'PSMP'; media = (Join-Path $D 'PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.2.1.zip') }
            Select-PASPsmpMediaForHost -Component $c -HostRecord $H -Directory 'x' -DataRoot $D
            $c.media | Should -BeLike '*Ubuntu24*'
            Mock Invoke-PASNativeQuiet { [pscustomobject]@{ ExitCode = 0; Output = 'rocky|8.10|rhel|Rocky Linux 8.10' } }
            { Select-PASPsmpMediaForHost -Component $c -HostRecord $H -Directory 'x' -DataRoot $D } | Should -Throw '*is for Ubuntu24*Rocky Linux 8.10*RHELinux8*'
        }
    }
}
