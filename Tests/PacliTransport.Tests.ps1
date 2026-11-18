BeforeAll {
    $helper=Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Vault/Recipes/Vault/Tasks/Common/PacliTransport.ps1'
    . $helper
}
Describe 'PACLI authenticated session proof and cleanup' {
    BeforeEach {
        $script:PacliAuthenticated=$false;$script:PacliOperations=[Collections.Generic.List[string]]::new()
        Mock Invoke-PAPacliSecretCommand {$script:PacliAuthenticated=$true;return @{Delivered=$true;ExitCode=0}}
        Mock Invoke-PAPacliProcess {
            param($Pacli,$Operation,$SessionId,$Arguments)
            $script:PacliOperations.Add($Operation)
            if($Operation -eq 'LOGOFF'){$script:PacliAuthenticated=$false}
            if($Operation -eq 'USERDETAILS'){
                if($script:PacliAuthenticated){return @{ExitCode=0;Out='"Administrator","NO"';Err=''}}
                return @{ExitCode=-1;Out='';Err='User is not logged on. Please log on.'}
            }
            return @{ExitCode=0;Out='';Err=''}
        }
    }
    It 'requires an independent authenticated query and a post-logoff negative control' {
        $session=Open-PAPacliVaultSession unused synthetic
        $session.Authenticated|Should -BeTrue
        $session.ContainsKey('Password')|Should -BeFalse
        Close-PAPacliVaultSession $session
        $session.Closed|Should -BeTrue
        ($script:PacliOperations -join ',')|Should -BeExactly 'INIT,DEFINE,DEFAULT,USERDETAILS,LOGOFF,USERDETAILS,TERM'
        Should -Invoke Invoke-PAPacliSecretCommand -Times 1 -Exactly
    }
    It 'rejects an unexpected identity even when native actions returned zero, and closes the session' {
        Mock Invoke-PAPacliProcess {
            param($Pacli,$Operation)
            $script:PacliOperations.Add($Operation)
            if($Operation -eq 'LOGOFF'){$script:PacliAuthenticated=$false}
            if($Operation -eq 'USERDETAILS'){
                if($script:PacliAuthenticated){return @{ExitCode=0;Out='"WrongIdentity","NO"';Err=''}}
                return @{ExitCode=-1;Out='';Err='User is not logged on. Please log on.'}
            }
            return @{ExitCode=0;Out='';Err=''}
        }
        {Open-PAPacliVaultSession unused synthetic}|Should -Throw '*authenticated session could not be established*'
        $script:PacliOperations[-1]|Should -BeExactly TERM
        Should -Invoke Invoke-PAPacliSecretCommand -Times 1 -Exactly
    }
    It 'retains uncertainty when a zero logoff does not actually close authentication' {
        $session=Open-PAPacliVaultSession unused synthetic
        Mock Invoke-PAPacliProcess {
            param($Pacli,$Operation)
            $script:PacliOperations.Add($Operation)
            if($Operation -eq 'USERDETAILS'){return @{ExitCode=0;Out='"Administrator","NO"';Err=''}}
            return @{ExitCode=0;Out='';Err=''}
        }
        {Close-PAPacliVaultSession $session}|Should -Throw '*PAExecUnknown*cleanup is unconfirmed*'
        $session.Closed|Should -BeFalse
        $script:PacliOperations[-1]|Should -BeExactly TERM
    }
}
Describe 'PACLI private batch construction' {
    It 'preserves qualified ASCII literals and quotes delimiters as data' {
        ConvertTo-PAPacliLiteral 'space ; back\slash'|Should -BeExactly '"space ; back\slash"'
        New-PAPacliSecretStatement LOGON 123 @{PASSWORD='synthetic; literal'}|Should -BeExactly ("LOGON PASSWORD=`"synthetic; literal`" SESSIONID=123;`r`n")
        New-PAPacliSecretStatement UPDATEUSER 123 @{DESTUSER='DR';DISABLED='NO';PASSWORD='synthetic'}|Should -BeExactly ("UPDATEUSER DESTUSER=`"DR`" DISABLED=NO PASSWORD=`"synthetic`" SESSIONID=123;`r`n")
    }
    It 'rejects unsupported characters before constructing any credential command' {
        foreach($character in @([char]0,[char]10,[char]13,[char]34,[char]127,[char]233)){
            {New-PAPacliSecretStatement LOGON 123 @{PASSWORD=('synthetic'+$character)}}|Should -Throw '*printable ASCII*'
        }
        {New-PAPacliSecretStatement LOGON 123 @{PASSWORD=''}}|Should -Throw '*empty*'
        {New-PAPacliSecretStatement LOGON 123 @{PASSWORD=(ConvertTo-SecureString synthetic -AsPlainText -Force)}}|Should -Throw '*fields must be strings*'
        {New-PAPacliSecretStatement UPDATEUSER 123 @{DESTUSER='DR';DISABLED='MAYBE';PASSWORD='synthetic'}}|Should -Throw '*disabled flag*'
        {New-PAPacliSecretStatement LOGON 123 @{PASSWORD='synthetic';EXTRA='field'}}|Should -Throw '*Unexpected*'
    }
    It 'creates a protected caller-and-SYSTEM-only pipe' -Skip:($env:OS -ne 'Windows_NT') {
        $name='PAEasy-Pacli-'+[guid]::NewGuid().ToString('N')
        $pipe=New-PAPacliInputPipe $name
        try{
            $acl=$pipe.GetAccessControl();$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $acl.AreAccessRulesProtected|Should -BeTrue
            $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value|Should -BeExactly $sid
            foreach($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){$ace.IdentityReference.Value|Should -BeIn @($sid,'S-1-5-18')}
        }finally{$pipe.Dispose()}
    }
    It 'rejects password-bearing process arguments before native process creation' -Skip:($env:OS -ne 'Windows_NT') {
        Mock Initialize-PAPacliPipeInterop {}
        Mock Assert-PAPacliBinary {return 'C:\not-executed.exe'}
        {Invoke-PAPacliProcess -Pacli unused -Operation DEFAULT -SessionId 123 -Arguments @('PASSWORD=synthetic')}|Should -Throw '*secret-bearing*'
    }
}
Describe 'PACLI binary admission' {
    It 'refuses an executable that is neither a reviewed build nor signed by CyberArk' -Skip:($env:OS -ne 'Windows_NT') {
        # whoami.exe is validly signed, but by Microsoft: a valid signature alone is not enough.
        $exe=Join-Path $env:SystemRoot 'System32\whoami.exe'
        {Assert-PAPacliBinary -Path $exe}|Should -Throw '*neither a reviewed build nor validly signed by CyberArk*'
    }
}
