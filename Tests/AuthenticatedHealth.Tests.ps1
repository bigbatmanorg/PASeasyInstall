BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'PASeasyInstall/Private/Diagnostics/Health.ps1')
    $credential=[pscredential]::new('Administrator',(ConvertTo-SecureString 'SYNTHETIC_HEALTH_PASSWORD_672' -AsPlainText -Force))
    $uri='https://pvwa.test/PasswordVault/API'
}
Describe 'Authenticated web health classification and cleanup' {
    BeforeEach {
        Mock Invoke-RestMethod {
            if($Uri -like '*/Auth/CyberArk/Logon'){return 'SYNTHETIC_HEALTH_TOKEN_581'}
            if($Uri -like '*/Auth/Logoff'){return}
            if($Uri -like '*Users?search=*'){return @{Users=@(@{username='Administrator'});Total=1}}
            if($Uri -like '*/Accounts/32_3'){return @{id='32_3';secret='SYNTHETIC_RESPONSE_SECRET_773';secretManagement=@{status='success';lastModifiedTime=12345}}}
            throw 'Unexpected endpoint'
        }
    }
    It 'proves authenticated PVWA, reads only explicit CPM status and never returns tokens/secrets' {
        $before=[Net.ServicePointManager]::SecurityProtocol
        $r=Invoke-PASAuthenticatedWebHealth $uri $credential -ControlledCPMAccountId 32_3
        $r.PVWA.OperationallyVerified|Should -BeTrue
        $r.SessionState|Should -BeExactly Closed
        $r.CPM.Passed|Should -BeTrue
        $r.CPM.OperationallyVerified|Should -BeFalse
        $r.CPM.NotTested|Should -Contain 'Independent controlled target authentication'
        ($r|ConvertTo-Json -Depth 8)|Should -Not -Match 'SYNTHETIC_HEALTH_TOKEN|SYNTHETIC_HEALTH_PASSWORD|SYNTHETIC_RESPONSE_SECRET'
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter {$Uri -like '*Password/Retrieve*'}
        Should -Invoke Invoke-RestMethod -Times 0 -ParameterFilter {$MaximumRedirection -ne 0}
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {$Uri -like '*/Auth/Logoff'}
        [Net.ServicePointManager]::SecurityProtocol|Should -Be $before
    }
    It 'requires the observed v15 Users envelope rather than assuming an Accounts value envelope' {
        Mock Invoke-RestMethod {return @{value=@(@{username='Administrator'})}} -ParameterFilter {$Uri -like '*Users?search=*'}
        $r=Invoke-PASAuthenticatedWebHealth $uri $credential
        $r.PVWA.OperationallyVerified|Should -BeFalse
        $r.FailureCode|Should -BeExactly UsersQueryFailed
        $r.SessionState|Should -BeExactly Closed
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {$Uri -like '*/Auth/Logoff'}
    }
    It 'requires valid Total metadata in the observed Users response envelope' {
        Mock Invoke-RestMethod {return @{Users=@(@{username='Administrator'})}} -ParameterFilter {$Uri -like '*Users?search=*'}
        $r=Invoke-PASAuthenticatedWebHealth $uri $credential
        $r.PVWA.OperationallyVerified|Should -BeFalse
        $r.FailureCode|Should -BeExactly UsersQueryFailed
        $r.SessionState|Should -BeExactly Closed
    }
    It 'always logs off after a failed authenticated query and suppresses server error text' {
        Mock Invoke-RestMethod {throw 'SYNTHETIC_HEALTH_PASSWORD_672 reflected by server'} -ParameterFilter {$Uri -like '*Users?search=*'}
        $r=Invoke-PASAuthenticatedWebHealth $uri $credential
        $r.PVWA.Passed|Should -BeFalse;$r.SessionState|Should -BeExactly Closed
        $r.FailureCode|Should -BeExactly UsersQueryFailed
        ($r|ConvertTo-Json -Depth 8)|Should -Not -Match 'SYNTHETIC_HEALTH_PASSWORD'
        Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {$Uri -like '*/Auth/Logoff'}
    }
    It 'marks an uncertain logoff as non-operational and retains uncertainty for the caller gate' {
        Mock Invoke-RestMethod {throw 'logout unavailable'} -ParameterFilter {$Uri -like '*/Auth/Logoff'}
        $r=Invoke-PASAuthenticatedWebHealth $uri $credential
        $r.SessionState|Should -BeExactly Unknown
        $r.PVWA.OperationallyVerified|Should -BeFalse
        $r.FailureCode|Should -BeExactly LogoffFailed
    }
    It 'refuses HTTP and invalid account identifiers before authentication' {
        (Invoke-PASAuthenticatedWebHealth 'http://pvwa.test/PasswordVault/API' $credential).FailureCode|Should -BeExactly InvalidHTTPSApiEndpoint
        {Invoke-PASAuthenticatedWebHealth $uri $credential -ControlledCPMAccountId '../bad'}|Should -Throw
        Should -Invoke Invoke-RestMethod -Times 0
    }
    It 'does not claim authenticated health when a custom certificate callback bypasses standard validation' {
        $previous=[Net.ServicePointManager]::ServerCertificateValidationCallback
        try{
            [Net.ServicePointManager]::ServerCertificateValidationCallback=[Net.Security.RemoteCertificateValidationCallback]{$true}
            $r=Invoke-PASAuthenticatedWebHealth $uri $credential
            $r.FailureCode|Should -BeExactly CustomControllerCertificateCallback
            $r.SessionState|Should -BeExactly NotOpened
            Should -Invoke Invoke-RestMethod -Times 0
        }finally{[Net.ServicePointManager]::ServerCertificateValidationCallback=$previous}
    }
}

Describe 'Malformed account metadata is not a reporting channel' {
    It 'suppresses unexpected status/timestamp values while safely closing the authenticated session' {
        Mock Invoke-RestMethod {
            if($Uri -like '*/Auth/CyberArk/Logon'){return 'synthetic-token-not-returned'}
            if($Uri -like '*/Auth/Logoff'){return}
            if($Uri -like '*Users?search=*'){return @{Users=@(@{username='Administrator'});Total=1}}
            return @{id='32_3';secretManagement=@{status='SYNTHETIC_RESPONSE_SECRET';lastModifiedTime='SYNTHETIC_RESPONSE_SECRET'}}
        }
        $r=Invoke-PASAuthenticatedWebHealth $uri $credential -ControlledCPMAccountId 32_3
        $r.CPM.Passed|Should -BeFalse
        $r.SessionState|Should -BeExactly Closed
        $r.PVWA.OperationallyVerified|Should -BeTrue
        ($r|ConvertTo-Json -Depth 8)|Should -Not -Match 'SYNTHETIC_RESPONSE_SECRET'
    }
}
Describe 'Ambiguous authentication transport outcome' {
    It 'keeps a dispatched logon timeout uncertain without exposing exception content' {
        Mock Invoke-RestMethod {throw [Net.WebException]::new('SYNTHETIC_SENSITIVE_TRANSPORT_TEXT',[Net.WebExceptionStatus]::Timeout)}
        $r=Invoke-PASAuthenticatedWebHealth $uri $credential
        $r.SessionState|Should -BeExactly Unknown
        $r.PVWA.OperationallyVerified|Should -BeFalse
        $r.FailureCode|Should -BeExactly LogonFailed
        ($r|ConvertTo-Json -Depth 8)|Should -Not -Match 'SYNTHETIC_SENSITIVE_TRANSPORT_TEXT'
    }
}
