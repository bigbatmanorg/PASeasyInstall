# Caller owns controller-wide credential coordination. Unknown session state must retain its claim.
function Invoke-PASAuthenticatedWebHealth {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uri]$ApiBaseUri,[Parameter(Mandatory)][pscredential]$Credential,
        [ValidatePattern('^(?:[0-9]+_[0-9]+)?$')][string]$ControlledCPMAccountId='',
        [ValidateRange(5,120)][int]$TimeoutSeconds=30)
    $pvwa=[ordered]@{Passed=$false;OperationallyVerified=$false;Level='AuthenticatedAPI';Evidence=@()}
    $cpm=if($ControlledCPMAccountId){[ordered]@{Passed=$false;OperationallyVerified=$false;Level='AccountStatus';AccountId=$ControlledCPMAccountId;Status='NotTested';LastModifiedTime=$null;NotTested=@('Independent controlled target authentication')}}else{$null}
    $result=[ordered]@{PVWA=$pvwa;CPM=$cpm;SessionState='NotOpened';TLSValidation='Required';FailureCode='';HTTPStatus=0;SecretPersisted=$false}
    if(-not $ApiBaseUri.IsAbsoluteUri -or $ApiBaseUri.Scheme -ine 'https' -or $ApiBaseUri.UserInfo -or $ApiBaseUri.Query -or $ApiBaseUri.Fragment -or $ApiBaseUri.AbsolutePath -notmatch '/API/?$'){$result.FailureCode='InvalidHTTPSApiEndpoint';return [pscustomobject]$result}
    if([Net.ServicePointManager]::ServerCertificateValidationCallback){$result.FailureCode='CustomControllerCertificateCallback';return [pscustomobject]$result}
    if(-not $Credential.UserName -or $Credential.Password.Length -eq 0){$result.FailureCode='MissingCredential';return [pscustomobject]$result}
    $base=$ApiBaseUri.AbsoluteUri.TrimEnd('/')+'/'
    $previousProtocol=[Net.ServicePointManager]::SecurityProtocol
    $token=$null;$headers=$null;$body=$null;$phase='Logon';$usersVerified=$false;$dispatched=$false
    try {
        [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
        $body=@{username=$Credential.UserName;password=$Credential.GetNetworkCredential().Password;concurrentSession=$false}|ConvertTo-Json -Compress
        $dispatched=$true
        $response=Invoke-RestMethod -Method Post -Uri ($base+'Auth/CyberArk/Logon') -ContentType application/json -Body $body -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -ErrorAction Stop -Verbose:$false -Debug:$false
        $body=$null
        if($response -isnot [string] -or [string]::IsNullOrWhiteSpace($response)){throw 'Unexpected logon response'}
        $token=$response;$response=$null;$headers=@{Authorization=$token};$result.SessionState='Open'
        $phase='UsersQuery'
        $users=Invoke-RestMethod -Method Get -Uri ($base+'Users?search='+[uri]::EscapeDataString($Credential.UserName)) -Headers $headers -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -ErrorAction Stop -Verbose:$false -Debug:$false
        $userTotal=[long]0
        if(-not [long]::TryParse([string]$users.Total,[ref]$userTotal) -or $userTotal -lt @($users.Users).Count){throw 'Unexpected Users response envelope'}
        $matching=@($users.Users|Where-Object {[string]$_.username -ieq $Credential.UserName})
        if(-not $matching.Count){throw 'Authenticated identity was not found by Users query'}
        $usersVerified=$true;$result.TLSValidation='Enabled';$pvwa.Evidence=@('HTTPS authenticated logon','Authenticated Users query returned the supplied identity')
        if($ControlledCPMAccountId){
            $phase='CPMAccountQuery'
            $account=Invoke-RestMethod -Method Get -Uri ($base+'Accounts/'+$ControlledCPMAccountId) -Headers $headers -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -ErrorAction Stop -Verbose:$false -Debug:$false
            if([string]$account.id -cne $ControlledCPMAccountId){throw 'Unexpected controlled account response'}
            $status=[string]$account.secretManagement.status
            if($status -notin @('success','failure','inProcess')){throw 'Unexpected controlled account status'}
            $modified=[long]0
            if(-not [long]::TryParse([string]$account.secretManagement.lastModifiedTime,[ref]$modified) -or $modified -lt 0){throw 'Unexpected controlled account timestamp'}
            $cpm.Status=$status;$cpm.LastModifiedTime=$modified
            $cpm.Passed=($status -eq 'success')
        }
    }catch{
        $failure=$_
        $result.FailureCode=($phase+'Failed')
        try{if($failure.Exception.Response){$result.HTTPStatus=[int]$failure.Exception.Response.StatusCode}}catch{}
        if(-not $token){
            $result.SessionState=if($dispatched){'Unknown'}else{'NotOpened'}
            if($result.HTTPStatus -in @(401,403)){$result.SessionState='NotOpened'}
            if($failure.Exception -is [Net.WebException] -and $failure.Exception.Status -in @([Net.WebExceptionStatus]::TrustFailure,[Net.WebExceptionStatus]::NameResolutionFailure,[Net.WebExceptionStatus]::ProxyNameResolutionFailure,[Net.WebExceptionStatus]::ConnectFailure)){$result.SessionState='NotOpened'}
        }
    }finally{
        if($token){
            try{
                Invoke-RestMethod -Method Post -Uri ($base+'Auth/Logoff') -Headers @{Authorization=$token} -TimeoutSec $TimeoutSeconds -MaximumRedirection 0 -ErrorAction Stop -Verbose:$false -Debug:$false|Out-Null
                $result.SessionState='Closed';$pvwa.Evidence+=@('Authenticated session logged off')
            }catch{$result.SessionState='Unknown';$result.FailureCode='LogoffFailed'}
        }
        $token=$null;$headers=$null;$body=$null;$response=$null
        [Net.ServicePointManager]::SecurityProtocol=$previousProtocol
    }
    $pvwa.Passed=($usersVerified -and $result.SessionState -eq 'Closed')
    $pvwa.OperationallyVerified=$pvwa.Passed
    if($cpm -and $result.SessionState -ne 'Closed'){$cpm.Passed=$false}
    return [pscustomobject]$result
}
