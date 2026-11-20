# Read-only diagnostics. Authenticated health uses the shared controller Vault gate.
function Get-PASRunLog {
    [CmdletBinding(DefaultParameterSetName='Run')]
    param([Parameter(ParameterSetName='Run',Mandatory)][string]$RunId,
          [Parameter(ParameterSetName='Remote',Mandatory)][string]$Config,
          [Parameter(ParameterSetName='Remote',Mandatory)][string]$Component,
          [Parameter(ParameterSetName='Remote')][string]$Name='default',
          [Parameter(ParameterSetName='Remote')][Management.Automation.PSCredential]$Credential,
          [string]$DataRoot=(Get-PASDataRoot),[ValidateRange(1,10000)][int]$Tail=200)
    if($PSCmdlet.ParameterSetName -eq 'Run'){
        $dir=Get-PASRunDirectory $RunId $DataRoot
        $file=Join-Path $dir 'events-v2.jsonl'
        if(-not(Test-Path $file)){return @()}
        return @(Get-Content -LiteralPath $file -Tail $Tail | ForEach-Object{try{$_ | ConvertFrom-Json}catch{}} | Where-Object {$_})
    }
    $c=Read-PASConfiguration -Path $Config
    $entry=@($c.components|Where-Object{$_.id -eq $Component})[0]
    if(-not $entry){throw "Unknown component: $Component"}
    $h=$c.hosts[[string]$entry.host]
    $t=[string]$entry.type
    $catalog=Get-PASLogSource
    $sources=@($catalog|Where-Object{$_.Component -eq $t})
    if(-not $sources.Count){throw "No qualified log sources defined for $t"}
    $source=@($sources|Where-Object{$_.Name -eq $Name})[0]
    if(-not $source){$source=$sources[0]}
    if($h.os -eq 'Windows'){
        if(-not $Credential){throw "-Credential required to read Windows logs on $($h.address)"}
        $inventory=New-PASRuntimeInventory -Config $c -RunDirectory '' -SkipMediaHash
        $target=$inventory.Targets[[string]$entry.id]
        $target.Remove('TransitionCredentialRef')
        $session=Get-PASConnection -Target $target -Credentials @{([string]$entry.id)=$Credential}
        try {
            return @(Invoke-Command -Session $session -ArgumentList @([string]$source.Path,$Tail) -ScriptBlock {
                param($path,$lines)
                # Never read arbitrary files; caller selected a known component log source.
                $items=@(Get-ChildItem -Path $path -File -ErrorAction SilentlyContinue)
                if($items.Count -eq 0){throw "Log source is not present: $path"}
                $latest=$items|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
                Get-Content -LiteralPath $latest.FullName -Tail $lines -ErrorAction Stop
            })
        }finally{Remove-PSSession $session}
    }
    $inventory=New-PASRuntimeInventory -Config $c -RunDirectory '' -SkipMediaHash
    $target=$inventory.Targets[[string]$entry.id]
    $log=[string]$source.Path
    if($log -notmatch '^/[a-zA-Z0-9_/.\*-]+$'){throw 'Unsafe log source'}
    # Catalog-only shell glob is deliberately unquoted after strict path validation.
    $command="tail -n $Tail -- $log"
    $result=Invoke-PASRawSSH $target $command
    if($result.ExitCode -ne 0){throw 'SSH log read failed; verify host key, access and path'}
    return @(([string]$result.Output) -split "`r?`n")
}
function Get-PASLogSource {
    [CmdletBinding()]param()
    $path=Join-Path $script:PASRoot 'Data/LogSources.json'
    if(-not(Test-Path $path)){return @()}
    return @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}
function Get-PASComponentStatus {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Config,[hashtable]$CredentialMap=@{})
    $assessment=Test-PASConfiguration -Config $Config
    if(-not $assessment.Valid){throw ('Configuration invalid: '+($assessment.Issues -join '; '))}
    $c=$assessment.Configuration
    foreach($component in @($c.components)){
        $id=[string]$component.id;$type=[string]$component.type
        $hostId=[string]$component.host;$hostObj=$c.hosts[$hostId]
        $entry=[ordered]@{Component=$id;Type=$type;Host=$hostId;Reachable=$false;ServiceStatus='Unknown';Verification='NotTested';Detail='';CheckedUtc=[DateTime]::UtcNow.ToString('o')}
        try {
            if($hostObj.os -eq 'Windows'){
                $credential=Get-PASHostCredential $c $CredentialMap $hostId $id
                if(-not $credential){throw "Missing CredentialMap for Windows host '$hostId'"}
                $names=switch($type){'Vault'{'PrivateArk Server'} 'DRVault'{'CyberArk Vault Disaster Recovery'} 'PVWA'{'CyberArk Scheduled Tasks'} 'CPM'{'CyberArk Password Manager'} 'PSM'{'CyberArk PSM|Cyber-?Ark Privileged Session Manager'} 'AD'{'NTDS'}}
                $inventory=New-PASRuntimeInventory -Config $c -RunDirectory '' -SkipMediaHash
                $target=$inventory.Targets[$id]
                $target.Remove('TransitionCredentialRef')
                $session=Get-PASConnection -Target $target -Credentials @{$id=$credential}
                try {
                $r=Invoke-Command -Session $session -ArgumentList $names -ScriptBlock {
                    param($name)
                    $services=@(Get-Service | Where-Object {$_.Name -match $name -or $_.DisplayName -match $name})
                    [pscustomobject]@{Count=$services.Count;Running=@($services|Where-Object{$_.Status -eq 'Running'}).Count;Names=@($services|ForEach-Object{$_.Name})}
                } -ErrorAction Stop
                } finally {Remove-PSSession $session}
                $entry.Reachable=$true
                $entry.ServiceStatus=if($r.Count -eq 0){'NotFound'}elseif($r.Running -eq $r.Count){'Running'}else{'Degraded'}
                $entry.Detail=(@($r.Names) -join ', ')
                $entry.Verification='ServiceProbeOnly'
            }else{
                $inventory=New-PASRuntimeInventory -Config $c -RunDirectory '' -SkipMediaHash
                $target=$inventory.Targets[$id]
                $service='psmpsrv'
                $result=Invoke-PASRawSSH $target "systemctl is-active '$service'"
                $entry.Reachable=($result.ExitCode -eq 0 -or -not [string]::IsNullOrWhiteSpace([string]$result.Output))
                $entry.ServiceStatus=if($result.ExitCode -eq 0){'Running'}else{'NotRunning'}
                $entry.Detail=[string]$result.Output
                $entry.Verification='ServiceProbeOnly'
            }
        }catch{$entry.Detail=[string]$_.Exception.Message}
        [pscustomobject]$entry
    }
}
function Test-PASDeploymentStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Config,[hashtable]$CredentialMap=@{},
        [pscredential]$VaultCredential,[uri]$ApiBaseUri,
        [ValidatePattern('^(?:[0-9]+_[0-9]+)?$')][string]$ControlledCPMAccountId='',
        [ValidatePattern('^[a-fA-F0-9]{32}$')][string]$HealthRunId=([guid]::NewGuid().ToString('N')),
        [string]$DataRoot=(Get-PASDataRoot))
    $statuses=@(Get-PASComponentStatus -Config $Config -CredentialMap $CredentialMap)
    foreach($status in $statuses){
        $status|Add-Member NoteProperty FunctionalVerification 'NotTested' -Force
        $status|Add-Member NoteProperty OperationallyVerified $false -Force
    }
    $failing=@($statuses|Where-Object{$_.ServiceStatus -ne 'Running'})
    $result=[ordered]@{ServicesHealthy=($failing.Count -eq 0);OperationallyVerified=$false;
        Mode='ServiceOnly';Components=$statuses;Health=$null;HealthRunId=$HealthRunId;ClaimRetained=$false;
        FailureCode='';Issues=@($failing|ForEach-Object {"$($_.Component): $($_.ServiceStatus)"});
        Message='Service-only probe. Component functional validation is NotTested.'}
    if(-not $VaultCredential){return [pscustomobject]$result}
    $result.Mode='AuthenticatedAPI'
    $gates=New-Object System.Collections.ArrayList
    $authenticationDispatched=$false;$releaseClaims=$true
    try {
        $configuration=Read-PASConfiguration -Path $Config
        $pvwas=@($configuration.components|Where-Object{$_.type -eq 'PVWA'})
        $selected=$null
        if(-not $ApiBaseUri){
            $configured=@($pvwas|Where-Object{$o=Get-PASValue $_ 'options' $null; $o -and (Get-PASValue $o 'pvwaUrl' '')})
            if($configured.Count -ne 1){$result.FailureCode='ExplicitApiBaseUriRequired';return [pscustomobject]$result}
            $selected=$configured[0]
            $url=([string](Get-PASValue (Get-PASValue $selected 'options' @{}) 'pvwaUrl' '')).TrimEnd('/')
            if($url -notmatch '/API$'){$url+='/API'}
            $parsed=$null
            if(-not [uri]::TryCreate($url,[UriKind]::Absolute,[ref]$parsed)){$result.FailureCode='InvalidHTTPSApiEndpoint';return [pscustomobject]$result}
            $ApiBaseUri=$parsed
        }elseif($pvwas.Count -eq 1){$selected=$pvwas[0]}
        if(-not $ApiBaseUri.IsAbsoluteUri -or $ApiBaseUri.Scheme -ine 'https' -or $ApiBaseUri.UserInfo -or $ApiBaseUri.Query -or $ApiBaseUri.Fragment -or $ApiBaseUri.AbsolutePath -notmatch '/API/?$'){
            $result.FailureCode='InvalidHTTPSApiEndpoint';return [pscustomobject]$result
        }
        if(-not [string]$configuration.vault.address){$result.FailureCode='VaultAddressRequired';return [pscustomobject]$result}
        $identities=@(Get-PASResourceIdentity -Address ([string]$configuration.vault.address)|Sort-Object -Unique)
        if(-not $identities.Count){$result.FailureCode='VaultResourceIdentityRequired';return [pscustomobject]$result}
        foreach($identity in $identities){
            [void]$gates.Add((Enter-PASGate -Name ('vault-'+$identity) -DataRoot $DataRoot -RunId $HealthRunId -TimeoutSeconds 30))
        }
        $preexisting=@($gates.ToArray()|Where-Object{
            $null -eq $_.PSObject.Properties['PreexistingClaim'] -or [bool]$_.PreexistingClaim
        })
        if($preexisting.Count){
            $result.FailureCode='HealthSessionReconciliationRequired'
            $result.Message='An unresolved prior health claim requires external session reconciliation. No new authentication was dispatched.'
        }else{
            # A dispatched request can create a session even if its response is lost.
            $authenticationDispatched=$true;$releaseClaims=$false
            $health=Invoke-PASAuthenticatedWebHealth -ApiBaseUri $ApiBaseUri -Credential $VaultCredential -ControlledCPMAccountId $ControlledCPMAccountId
            $result.Health=$health
            $releaseClaims=($health.SessionState -in @('Closed','NotOpened'))
            $result.FailureCode=[string]$health.FailureCode
            foreach($status in $statuses){
                if($selected -and $status.Component -eq $selected.id){
                    $status.FunctionalVerification=if($health.PVWA.Passed -and $health.SessionState -eq 'Closed'){'AuthenticatedAPI'}else{'Failed'}
                    $status.OperationallyVerified=([bool]$health.PVWA.OperationallyVerified -and $health.SessionState -eq 'Closed')
                }elseif($status.Type -eq 'CPM' -and $ControlledCPMAccountId){
                    $status.FunctionalVerification='ControlledAccountStatusOnly'
                }
            }
            $result.Message='Authenticated API results are component-specific. CPM status and service probes do not prove end-to-end operation.'
        }
    }catch{
        $result.FailureCode=if($authenticationDispatched){'AuthenticatedHealthFailed'}else{'HealthCoordinationFailed'}
        $result.Message='Health validation could not complete. Inspect the reported classification and reconcile any retained claim before another session.'
    }finally{
        $result.ClaimRetained=($gates.Count -gt 0 -and -not $releaseClaims)
        foreach($gate in @($gates.ToArray())){
            $priorClaim=($null -eq $gate.PSObject.Properties['PreexistingClaim'] -or [bool]$gate.PreexistingClaim)
            if($priorClaim){
                $result.ClaimRetained=$true
                if(-not $authenticationDispatched){
                    $result.FailureCode='HealthSessionReconciliationRequired'
                    $result.Message='An unresolved prior health claim requires external session reconciliation. No new authentication was dispatched.'
                }
            }
            try{if($releaseClaims -and -not $priorClaim){$gate.Complete()}}
            catch{$result.ClaimRetained=$true;$result.FailureCode='HealthGateCleanupFailed'}
            finally{
                try{$gate.Dispose()}catch{$result.ClaimRetained=$true;$result.FailureCode='HealthGateCleanupFailed'}
            }
        }
    }
    return [pscustomobject]$result
}
