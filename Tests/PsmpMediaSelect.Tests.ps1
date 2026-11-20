# PSMP packages are per distribution. The deployment carries one selected package; once SSH works, the
# controller must use the package for the server's OS (a Rocky 9 server was sent the Ubuntu .deb package).
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-PASTestModule
    $script:host9 = @{ address = '192.0.2.46'; user = 'root'; identityFile = 'k'; knownHostsFile = 'kh' }
}
Describe 'PSMP package for the server distribution' {
    It 'maps os-release to the vendor variant' {
        InModuleScope PASeasyInstall {
            Get-PASPsmpVariantForOs 'ubuntu' '24.04' 'debian' | Should -Be 'Ubuntu24'
            Get-PASPsmpVariantForOs 'rocky' '9.8' 'rhel centos fedora' | Should -Be 'RHELinux9'
            Get-PASPsmpVariantForOs 'almalinux' '8.10' 'rhel centos fedora' | Should -Be 'RHELinux8'
            Get-PASPsmpVariantForOs 'rhel' '9.4' 'fedora' | Should -Be 'RHELinux9'
            Get-PASPsmpVariantForOs 'debian' '12' '' | Should -Be ''
        }
    }
    It 'switches to the matching package from the same folder' {
        $dir = Join-Path $TestDrive 'plain'
        New-Item -ItemType Directory $dir | Out-Null
        $u = Join-Path $dir 'PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.2.1.zip'
        $r = Join-Path $dir 'PrivilegedSessionManagerSSHProxy-RHELinux9-Intel64-Rls-v15.2.1.zip'
        Set-Content $u 'u'
        Set-Content $r 'r'
        InModuleScope PASeasyInstall -Parameters @{ U = $u; R = $r; H = $script:host9 } {
            param($U, $R, $H)
            Mock Invoke-PASNativeQuiet { [pscustomobject]@{
                    ExitCode = 0
                    Output = "NAME=`"Rocky Linux`"`nVERSION_ID=`"9.8`"`nID=`"rocky`"`nID_LIKE=`"rhel centos fedora`"`nPRETTY_NAME=`"Rocky Linux 9.8 (Blue Onyx)`""
                } }
            Mock Write-PASRunEvent {}
            $c = @{ id = 'psmp'; type = 'PSMP'; media = $U; mediaSource = @{ path = $U; entry = '' } }
            Select-PASPsmpMediaForHost -Component $c -HostRecord $H -Directory 'x' -DataRoot $TestDrive
            $c.media | Should -Be $R
            Should -Invoke Write-PASRunEvent -Times 1 -ParameterFilter { $Message -like '*RHELinux9*Rocky Linux 9.8*' }
        }
    }
    It 'switches to the matching package inside the same bundle' {
        $bundle = Join-Path $TestDrive 'PAM-15.2.zip'
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::Open($bundle, 'Create')
        foreach ($n in 'PSMP/PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.2.1.zip', 'PSMP/PrivilegedSessionManagerSSHProxy-RHELinux9-Intel64-Rls-v15.2.1.zip') {
            $w = New-Object IO.StreamWriter ($z.CreateEntry($n).Open())
            $w.Write($n)
            $w.Dispose()
        }
        $z.Dispose()
        InModuleScope PASeasyInstall -Parameters @{ B = $bundle; H = $script:host9 } {
            param($B, $H)
            Mock Invoke-PASNativeQuiet { [pscustomobject]@{
                    ExitCode = 0
                    Output = "ID=rocky`nVERSION_ID=9.8`nID_LIKE='rhel centos fedora'`nPRETTY_NAME=`"Rocky Linux 9.8`""
                } }
            Mock Write-PASRunEvent {}
            $c = @{ id = 'psmp'
                type = 'PSMP'
                media = 'C:\cache\PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.2.1.zip'
                mediaSource = @{
                    path = $B
                    entry = 'PSMP/PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.2.1.zip'
                }
            }
            Select-PASPsmpMediaForHost -Component $c -HostRecord $H -Directory 'x' -DataRoot $TestDrive
            [IO.Path]::GetFileName($c.media) | Should -Be 'PrivilegedSessionManagerSSHProxy-RHELinux9-Intel64-Rls-v15.2.1.zip'
            Test-Path -LiteralPath $c.media | Should -BeTrue
        }
    }
    It 'keeps a package that already matches and stops clearly when none matches' {
        InModuleScope PASeasyInstall -Parameters @{ H = $script:host9; D = $TestDrive } {
            param($H, $D)
            Mock Write-PASRunEvent {}
            Mock Invoke-PASNativeQuiet { [pscustomobject]@{
                    ExitCode = 0
                    Output = "ID=ubuntu`nVERSION_ID=`"24.04`"`nID_LIKE=debian`nPRETTY_NAME=`"Ubuntu 24.04`""
                } }
            $c = @{
                id = 'psmp'
                type = 'PSMP'
                media = (Join-Path $D 'PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.2.1.zip')
            }
            Select-PASPsmpMediaForHost -Component $c -HostRecord $H -Directory 'x' -DataRoot $D
            $c.media | Should -BeLike '*Ubuntu24*'
            Mock Invoke-PASNativeQuiet { [pscustomobject]@{
                    ExitCode = 0
                    Output = "ID=`"rocky`"`nVERSION_ID=`"8.10`"`nID_LIKE=`"rhel`"`nPRETTY_NAME=`"Rocky Linux 8.10`""
                } }
            { Select-PASPsmpMediaForHost -Component $c -HostRecord $H -Directory 'x' -DataRoot $D } |
                Should -Throw '*is for Ubuntu24*Rocky Linux 8.10*RHELinux8*'
        }
    }
    It 'sends a remote command the SSH tool wrapper accepts' {
        InModuleScope PASeasyInstall -Parameters @{ H = $script:host9; D = $TestDrive } {
            param($H, $D)
            Mock Write-PASRunEvent {}
            Mock Invoke-PASNativeQuiet {
                foreach ($a in $Arguments) { if ([string]$a -match '["%!\r\n]') { throw 'Unsupported character in an SSH tool argument' } }
                [pscustomobject]@{
                    ExitCode = 0
                    Output = "ID=ubuntu`nVERSION_ID=24.04"
                }
            }
            $c = @{
                id = 'psmp'
                type = 'PSMP'
                media = (Join-Path $D 'PrivilegedSessionManagerSSHProxy-Ubuntu24-Intel64-Rls-v15.2.1.zip')
            }
            { Select-PASPsmpMediaForHost -Component $c -HostRecord $H -Directory 'x' -DataRoot $D } | Should -Not -Throw
        }
    }
}
