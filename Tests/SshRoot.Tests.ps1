# Linux servers are installed as root: a non-root sign-in must stop at the SSH bootstrap with a clear message
# (it used to fail later, at media upload, with "mkdir: cannot create directory '/opt/paeasyinstall'").
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1'); Import-PASTestModule
}
Describe 'Linux sign-in account' {
    It 'accepts root' {
        InModuleScope PASeasyInstall {
            Mock Invoke-PASNativeQuiet { [pscustomobject]@{ ExitCode = 0; Output = "0`n" } }
            { Assert-PASSshRoot 'k' @() 'root' '192.0.2.5' } | Should -Not -Throw
        }
    }
    It 'refuses a non-root account and says what to do' {
        InModuleScope PASeasyInstall {
            Mock Invoke-PASNativeQuiet { [pscustomobject]@{ ExitCode = 0; Output = '1000' } }
            { Assert-PASSshRoot 'k' @() 'rocky' '192.0.2.5' } | Should -Throw "*rocky@192.0.2.5 is not root*root account*"
        }
    }
    It 'runs id -u over the controller key' {
        InModuleScope PASeasyInstall {
            Mock Invoke-PASNativeQuiet { [pscustomobject]@{ ExitCode = 0; Output = '0' } }
            Assert-PASSshRoot 'C:\k' @('-n') 'root' '192.0.2.5'
            Should -Invoke Invoke-PASNativeQuiet -Times 1 -ParameterFilter { $Arguments[-1] -eq 'id -u' -and $Arguments -contains 'C:\k' }
        }
    }
}
