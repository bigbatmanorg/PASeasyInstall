BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $root = Join-Path $repo 'PASeasyInstall/Recipes/Vault/Tasks'
    . (Join-Path $root 'Common/PacliTransport.ps1')
    $global:PAeasyPacliRecipeFixture = @{}
    function Invoke-PacliRecipe([string]$Name, [hashtable]$Parameters) { & (Join-Path $root $Name) @Parameters }
}
AfterAll { Remove-Variable -Scope Global -Name PAeasyPacliRecipeFixture -ErrorAction SilentlyContinue }
Describe 'Vault recipes use private native input and independent session evidence' {
    BeforeEach {
        $global:PAeasyPacliRecipeFixture.Authenticated = $false
        $global:PAeasyPacliRecipeFixture.SafeExists = $false
        $global:PAeasyPacliRecipeFixture.DrEnabled = $false
        $global:PAeasyPacliRecipeFixture.Argv = [Collections.Generic.List[string]]::new()
        $global:PAeasyPacliRecipeFixture.Ops = [Collections.Generic.List[string]]::new()
        $parameters = @{
            Settings = @{
                PackagesRoot = 'C:\fixture\packages'
                InstallRoot = 'C:\fixture\PrivateArk'
            }
            AdminPassword = 'synthetic-admin;literal'
            DRPassword = 'synthetic-dr\literal'
            RunId = '0123456789abcdef0123456789abcdef'
        }
        Mock Assert-PAPacliBinary { return 'C:\fixture\Pacli.exe' }
        Mock Get-Service { [pscustomobject]@{Name = 'fixture-service'; Status = 'Running' } }
        Mock Set-Service {}
        Mock Start-Service {}
        Mock Invoke-PAPacliSecretCommand {
            param($Pacli, $Operation, $SessionId, $Values)
            $global:PAeasyPacliRecipeFixture.Ops.Add('PIPE-' + $Operation)
            if ($Operation -eq 'LOGON') { $global:PAeasyPacliRecipeFixture.Authenticated = $true }
            if ($Operation -eq 'UPDATEUSER') { $global:PAeasyPacliRecipeFixture.DrEnabled = $true }
            return @{ExitCode = 0; Delivered = $true }
        }
        Mock Invoke-PAPacliProcess {
            param($Pacli, $Operation, $SessionId, $Arguments)
            $global:PAeasyPacliRecipeFixture.Ops.Add($Operation)
            foreach ($argument in $Arguments) { $global:PAeasyPacliRecipeFixture.Argv.Add($argument) }
            if ($Operation -eq 'LOGOFF') { $global:PAeasyPacliRecipeFixture.Authenticated = $false }
            if ($Operation -eq 'ADDSAFE') { $global:PAeasyPacliRecipeFixture.SafeExists = $true }
            if ($Operation -eq 'USERDETAILS') {
                if (-not $global:PAeasyPacliRecipeFixture.Authenticated) {
                    return @{
                        ExitCode = -1
                        Out = ''
                        Err = 'User is not logged on. Please log on.'
                    }
                }
                if ($Arguments -contains 'DESTUSER=DR') { return @{ExitCode = 0; Out = '"DR","NO"'; Err = '' } }
                return @{ExitCode = 0; Out = '"Administrator","NO"'; Err = '' }
            }
            if ($Operation -eq 'OPENSAFE') {
                if ($global:PAeasyPacliRecipeFixture.SafeExists) { return @{ExitCode = 0; Out = '"71"'; Err = '' } }
                $name = ($Arguments | Where-Object { $_ -like 'SAFE=*' }).Substring(5)
                return @{ExitCode = -1; Out = ''; Err = ("ITATS020E Safe Name " + $name + " hasn't been defined.") }
            }
            return @{ExitCode = 0; Out = ''; Err = '' }
        }
    }
    It 'validates unsupported DR text before touching any service or native process' {
        $parameters.DRPassword = 'bad"literal'
        { Invoke-PacliRecipe 'Vault/Configure-Primary.ps1' @{
                Settings = $parameters.Settings
                AdminPassword = $parameters.AdminPassword
                DRPassword = $parameters.DRPassword
            } } |
            Should -Throw '*printable ASCII*'
        Should -Invoke Get-Service -Times 0
        Should -Invoke Set-Service -Times 0
        Should -Invoke Invoke-PAPacliProcess -Times 0
    }
    It 'updates DR only through the pipe and verifies exact enabled state before closure' {
        $result = Invoke-PacliRecipe 'Vault/Configure-Primary.ps1' @{
            Settings = $parameters.Settings
            AdminPassword = $parameters.AdminPassword
            DRPassword = $parameters.DRPassword
        }
        $result.Changed | Should -BeTrue
        $result.Data.Pacli | Should -Match 'dr-enabled=verified'
        $global:PAeasyPacliRecipeFixture.Ops[-1] | Should -Be TERM
        $global:PAeasyPacliRecipeFixture.Authenticated | Should -BeFalse
        ($global:PAeasyPacliRecipeFixture.Argv -join '|') | Should -Not -Match 'synthetic|PASSWORD'
        Should -Invoke Invoke-PAPacliSecretCommand -Times 1 -ParameterFilter { $Operation -eq 'UPDATEUSER' -and $Values.PASSWORD -eq 'synthetic-dr\literal' }
    }
    It 'rejects false-zero DR query diagnostics and still performs isolated-session cleanup' {
        Mock Invoke-PAPacliProcess { return @{
                ExitCode = 0
                Out = '"DR","NO"'
                Err = 'diagnostic'
            } } -ParameterFilter { $Operation -eq 'USERDETAILS' -and $Arguments -contains 'DESTUSER=DR' }
        { Invoke-PacliRecipe 'Vault/Configure-Primary.ps1' @{
                Settings = $parameters.Settings
                AdminPassword = $parameters.AdminPassword
                DRPassword = $parameters.DRPassword
            } } |
            Should -Throw '*DR enabled-state*'
        $global:PAeasyPacliRecipeFixture.Ops[-1] | Should -Be TERM
        $global:PAeasyPacliRecipeFixture.Authenticated | Should -BeFalse
    }
    It 'creates only after the qualified exact-name missing diagnostic and independently opens and closes' {
        $result = Invoke-PacliRecipe 'Vault/New-TestSafe.ps1' @{
            Settings = $parameters.Settings
            AdminPassword = $parameters.AdminPassword
            RunId = $parameters.RunId
        }
        $result.Changed | Should -BeTrue
        $result.Data.SafeName | Should -BeExactly 'PAExecRepl0123456789ab'
        ($global:PAeasyPacliRecipeFixture.Ops -join ',') | Should -Match 'OPENSAFE,ADDSAFE,OPENSAFE,CLOSESAFE,LOGOFF,USERDETAILS,TERM'
        $global:PAeasyPacliRecipeFixture.Authenticated | Should -BeFalse
        ($global:PAeasyPacliRecipeFixture.Argv -join '|') | Should -Not -Match 'synthetic|PASSWORD'
    }
    It 'does not duplicate an independently verified existing test Safe' {
        $global:PAeasyPacliRecipeFixture.SafeExists = $true
        (Invoke-PacliRecipe 'Vault/New-TestSafe.ps1' @{
            Settings = $parameters.Settings
            AdminPassword = $parameters.AdminPassword
            RunId = $parameters.RunId
        }).Changed |
            Should -BeFalse
        Should -Invoke Invoke-PAPacliProcess -Times 0 -ParameterFilter { $Operation -eq 'ADDSAFE' }
    }
    It 'never treats network/authentication errors or another Safe name as missing' -TestCases @(
        @{ErrorText = 'Connection failed' }, @{ErrorText = "ITATS020E Safe Name Other hasn't been defined." }, @{ErrorText = 'User is not logged on. Please log on.' }
    ) { param($ErrorText)
        $global:PAeasyPacliRecipeFixture.ErrorText = $ErrorText
        Mock Invoke-PAPacliProcess { return @{
                ExitCode = -1
                Out = ''
                Err = $global:PAeasyPacliRecipeFixture.ErrorText
            } } -ParameterFilter { $Operation -eq 'OPENSAFE' }
        { Invoke-PacliRecipe 'Vault/New-TestSafe.ps1' @{
                Settings = $parameters.Settings
                AdminPassword = $parameters.AdminPassword
                RunId = $parameters.RunId
            } } |
            Should -Throw '*Safe access is unconfirmed*'
        Should -Invoke Invoke-PAPacliProcess -Times 0 -ParameterFilter { $Operation -eq 'ADDSAFE' }
        $global:PAeasyPacliRecipeFixture.Ops[-1] | Should -Be TERM
    }
    It 'refuses a false-zero Safe open with missing identity output' {
        Mock Invoke-PAPacliProcess { return @{ExitCode = 0; Out = ''; Err = '' } } -ParameterFilter { $Operation -eq 'OPENSAFE' }
        { Invoke-PacliRecipe 'Verify/Verify-TestSafe.ps1' @{
                Settings = $parameters.Settings
                AdminPassword = $parameters.AdminPassword
                RunId = $parameters.RunId
            } } |
            Should -Throw '*Safe access is unconfirmed*'
        $global:PAeasyPacliRecipeFixture.Ops[-1] | Should -Be TERM
    }
    It 'returns typed failed and satisfied Safe checks only after known closure' {
        $missing = Invoke-PacliRecipe 'Verify/Verify-TestSafe.ps1' @{
            Settings = $parameters.Settings
            AdminPassword = $parameters.AdminPassword
            RunId = $parameters.RunId
        }
        $missing.Passed | Should -BeFalse
        $missing.SessionClosed | Should -BeTrue
        $global:PAeasyPacliRecipeFixture.SafeExists = $true
        $present = Invoke-PacliRecipe 'Verify/Verify-TestSafe.ps1' @{
            Settings = $parameters.Settings
            AdminPassword = $parameters.AdminPassword
            RunId = $parameters.RunId
        }
        $present.Passed | Should -BeTrue
        $present.SessionClosed | Should -BeTrue
    }
    It 'never converts uncertain TERM cleanup into a typed closed check' {
        $global:PAeasyPacliRecipeFixture.SafeExists = $true
        Mock Invoke-PAPacliProcess { return @{
                ExitCode = 0
                Out = ''
                Err = 'term diagnostic'
            } } -ParameterFilter { $Operation -eq 'TERM' }
        { Invoke-PacliRecipe 'Verify/Verify-TestSafe.ps1' @{
                Settings = $parameters.Settings
                AdminPassword = $parameters.AdminPassword
                RunId = $parameters.RunId
            } } |
            Should -Throw '*PAExecUnknown*cleanup is unconfirmed*'
    }
    It 'requires independent access after ADDSAFE instead of trusting exit zero' {
        Mock Invoke-PAPacliProcess { return @{ExitCode = 0; Out = ''; Err = '' } } -ParameterFilter { $Operation -eq 'ADDSAFE' }
        { Invoke-PacliRecipe 'Vault/New-TestSafe.ps1' @{
                Settings = $parameters.Settings
                AdminPassword = $parameters.AdminPassword
                RunId = $parameters.RunId
            } } |
            Should -Throw '*Safe access is unconfirmed*'
    }
    It 'rejects an invalid run identity before authentication or Safe mutation' {
        { Invoke-PacliRecipe 'Vault/New-TestSafe.ps1' @{
                Settings = $parameters.Settings
                AdminPassword = $parameters.AdminPassword
                RunId = 'bad;name'
            } } |
            Should -Throw '*complete hexadecimal*'
        Should -Invoke Invoke-PAPacliProcess -Times 0
    }
}
Describe 'Primary acceptance Check has explicit authentication and closure boundaries' {
    BeforeEach {
        $global:PAeasyPacliRecipeFixture.Auth = $false
        $params = @{
            Settings = @{
                PackagesRoot = 'C:\fixture\packages'
                InstallRoot = 'C:\fixture\PrivateArk'
            }
            AdminPassword = 'synthetic-admin'
            ReadinessTimeoutSeconds = 0
        }
        Mock Get-Service { [pscustomobject]@{Status = 'Running' } }
        Mock Test-Path { $true }
        Mock Get-CimInstance { [pscustomobject]@{LastBootUpTime = [datetime]'2026-11-17T01:00:00' } }
        Mock Get-Content { param($LiteralPath)
            if ($LiteralPath -like '*italog.log') { return '17/11/2026 02:00:00 ITADB313I Server fixture is up' }
            return '<LicenseXML><Limitations><LicenseLimitations><ExpirationDate>future</ExpirationDate></LicenseLimitations></Limitations></LicenseXML>'
        }
        Mock Invoke-PAPacliSecretCommand {
            $global:PAeasyPacliRecipeFixture.Auth = $true
            return @{
                ExitCode = 0
                Delivered = $true
            }
        }
        Mock Invoke-PAPacliProcess {
            param($Operation)
            if ($Operation -eq 'LOGOFF') { $global:PAeasyPacliRecipeFixture.Auth = $false }
            if ($Operation -eq 'USERDETAILS') {
                if ($global:PAeasyPacliRecipeFixture.Auth) { return @{ExitCode = 0; Out = '"Administrator","NO"'; Err = '' } }
                return @{ExitCode = -1; Out = ''; Err = 'User is not logged on. Please log on.' }
            }
            return @{ExitCode = 0; Out = ''; Err = '' }
        }
    }
    It 'preserves service/current-boot/log/license checks and reports real independent identity closure' {
        $result = Invoke-PacliRecipe 'Verify/Verify-Primary.ps1' $params
        $result.Passed | Should -BeTrue
        $result.SessionClosed | Should -BeTrue
        $result.Evidence | Should -Contain 'PACLI independent authenticated identity verified'
        $result.Evidence | Should -Contain 'ITADB313I current-boot server-up record verified'
        $result.Evidence | Should -Contain 'license expiration future'
    }
    It 'does not open a session when local readiness is false' {
        Mock Get-Service { [pscustomobject]@{Status = 'Stopped' } }
        $result = Invoke-PacliRecipe 'Verify/Verify-Primary.ps1' $params
        $result.Passed | Should -BeFalse
        $result.SessionClosed | Should -BeTrue
        Should -Invoke Invoke-PAPacliSecretCommand -Times 0
        $result.Evidence | Should -Contain 'PACLI authNotAttempted: local readiness failed'
    }
    It 'rejects stale preboot server-up evidence without logging on' {
        Mock Get-Content { return '16/11/2026 02:00:00 ITADB313I Server fixture is up' } -ParameterFilter { $LiteralPath -like '*italog.log' }
        $result = Invoke-PacliRecipe 'Verify/Verify-Primary.ps1' $params
        $result.Passed | Should -BeFalse
        $result.SessionClosed | Should -BeTrue
        Should -Invoke Invoke-PAPacliSecretCommand -Times 0
    }
    It 'returns failed only for authenticated-identity failure with typed known closure' {
        Mock Invoke-PAPacliProcess { return @{
                ExitCode = 0
                Out = '"Wrong","NO"'
                Err = ''
            } } -ParameterFilter { $Operation -eq 'USERDETAILS' -and $global:PAeasyPacliRecipeFixture.Auth }
        $result = Invoke-PacliRecipe 'Verify/Verify-Primary.ps1' $params
        $result.Passed | Should -BeFalse
        $result.SessionClosed | Should -BeTrue
        $global:PAeasyPacliRecipeFixture.Auth | Should -BeFalse
    }
    It 'throws when cleanup uncertainty prevents SessionClosed evidence' {
        Mock Invoke-PAPacliProcess { return @{
                ExitCode = 0
                Out = ''
                Err = 'diagnostic'
            } } -ParameterFilter { $Operation -eq 'TERM' }
        { Invoke-PacliRecipe 'Verify/Verify-Primary.ps1' $params } | Should -Throw '*PAExecUnknown*cleanup is unconfirmed*'
    }
}
Describe 'Native result and argument regression boundaries' {
    It 'does not accept absent capture fields, error text with zero, or wrong logout diagnostics' {
        Test-PAPacliCleanAcknowledgement @{ExitCode = 0 } | Should -BeFalse
        Test-PAPacliCleanAcknowledgement @{ExitCode = 0; Out = ''; Err = 'diagnostic' } | Should -BeFalse
        Test-PAPacliLoggedOutResult @{
            ExitCode = -1
            Out = 'unexpected'
            Err = 'User is not logged on. Please log on.'
        } | Should -BeFalse
        Test-PAPacliLoggedOutResult @{ExitCode = -1; Out = ''; Err = 'network failure: user is not logged on' } | Should -BeFalse
    }
    It 'has a fixed include marker and no raw native PACLI invocation or password process argument in any recipe' {
        foreach ($file in @('Vault/Configure-Primary.ps1', 'Vault/New-TestSafe.ps1', 'Verify/Verify-Primary.ps1', 'Verify/Verify-TestSafe.ps1')) {
            $text = Get-Content (Join-Path $root $file) -Raw
            $text | Should -Match '# PAEASY_INCLUDE_VAULT_PACLI'
            $text | Should -Not -Match '&\s*\$pacli|password=\s*\x27?\s*\+|LASTEXITCODE'
        }
    }
}

Describe 'Actual TaskHost Check wrapper consumes assembled PACLI recipes' {
    It 'returns typed closure only when the check established it' -TestCases @(
        @{Mode = 'Available'; ExpectedOk = $true; ExpectedPassed = $true },
        @{Mode = 'Unavailable'; ExpectedOk = $true; ExpectedPassed = $false },
        @{Mode = 'UnknownCleanup'; ExpectedOk = $false; ExpectedPassed = $false }
    ) { param($Mode, $ExpectedOk, $ExpectedPassed)
        $helper = Get-Content (Join-Path $root 'Common/PacliTransport.ps1') -Raw
        $stubs = @'
$script:HostedMode='__MODE__';$script:HostedAuth=$false
function Get-Service {[CmdletBinding()]param($DisplayName) if($script:HostedMode -eq 'Unavailable'){[pscustomobject]@{Status='Stopped'}}else{[pscustomobject]@{Status='Running'}}}
function Test-Path {[CmdletBinding()]param($LiteralPath) return $true}
function Get-CimInstance {[CmdletBinding()]param($ClassName) [pscustomobject]@{LastBootUpTime=[datetime]'2026-11-17T01:00:00'}}
function Get-Content {[CmdletBinding()]param($LiteralPath,$Tail,[switch]$Raw) if($LiteralPath -like '*italog.log'){'17/11/2026 02:00:00 ITADB313I Server fixture is up'}else{'<LicenseXML/>'}}
function Invoke-PAPacliSecretCommand {param($Pacli,$Operation,$SessionId,$Values) $script:HostedAuth=$true;return @{ExitCode=0;Delivered=$true}}
function Invoke-PAPacliProcess {
param($Pacli,$Operation,$SessionId,$Arguments)
if($script:HostedMode -eq 'Unavailable'){throw 'Authentication must not start for failed local readiness'}
if($Operation -eq 'LOGOFF'){$script:HostedAuth=$false}
if($Operation -eq 'TERM' -and $script:HostedMode -eq 'UnknownCleanup'){return @{ExitCode=0;Out='';Err='diagnostic'}}
if($Operation -eq 'USERDETAILS'){if($script:HostedAuth){return @{ExitCode=0;Out='"Administrator","NO"';Err=''}};return @{ExitCode=-1;Out='';Err='User is not logged on. Please log on.'}}
return @{ExitCode=0;Out='';Err=''}
}
'@
        $stubs = $stubs.Replace('__MODE__', $Mode)
        $text = (Get-Content (Join-Path $root 'Verify/Verify-Primary.ps1') -Raw).Replace('# PAEASY_INCLUDE_VAULT_PACLI', ($helper + [char]10 + $stubs))
        $hostPath = Join-Path $repo 'PASeasyInstall/Private/Engine/Assets/TaskHost.ps1'
        $result = & $hostPath -Code $text -Parameters @{
            Settings = @{
                PackagesRoot = 'C:\fixture\packages'
                InstallRoot = 'C:\fixture\PrivateArk'
            }
            AdminPassword = 'synthetic-hosted'
            ReadinessTimeoutSeconds = 0
        } -Contract Check
        $result.Ok | Should -Be $ExpectedOk
        if ($ExpectedOk) {
            $result.Check.passed | Should -Be $ExpectedPassed
            $result.Check.sessionClosed | Should -BeTrue
        } else {
            $result.Check | Should -BeNullOrEmpty
            $result.Error | Should -Match 'cleanup is unconfirmed'
        }
    }
}
