# Vendor PSM stages run under the engine's durable Windows attempt. The controller owns reboots.
# No interactive logon, RunOnce continuation, or Winlogon password is required by this path.
function Assert-PASeasyPsmNoInteractiveContinuation {
    $winlogon=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    if($winlogon -and $winlogon.PSObject.Properties['DefaultPassword']){throw 'PSM refuses plaintext Winlogon continuation; reconcile vendor state before proceeding'}
    $runOnce=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -ErrorAction SilentlyContinue
    if($runOnce -and @($runOnce.PSObject.Properties | Where-Object {$_.Value -is [string] -and $_.Value -match 'InstallationAutomationRecovery\.ps1'}).Count){throw 'Vendor interactive recovery detected; reconcile before executing PSM stages'}
}
function Assert-PASeasyPsmTlsBackupData {
    param([Parameter(Mandatory)][string]$Path)
    $file=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if($file.Length -gt 131072){throw 'PSM TLS backup exceeds the expected registry export size'}
    $text=[IO.File]::ReadAllText($Path)
    $lines=@($text -split "`r?`n")
    if(-not $lines.Count -or $lines[0].Trim() -cne 'Windows Registry Editor Version 5.00'){throw 'PSM TLS backup is not a canonical registry export'}
    $expected='HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Client'
    foreach($line in $lines){
        $trimmed=$line.Trim()
        if(-not $trimmed.StartsWith('[')){continue}
        if($trimmed -notmatch '^\[([^\]]+)\]$'){throw 'PSM TLS backup contains a malformed registry key'}
        $key=$matches[1]
        if($key -ine $expected -and -not $key.StartsWith($expected+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'PSM TLS backup contains registry keys outside the native TLS client scope'}
    }
}
function Assert-PASeasyPsmAncestorAcl {
    param([Parameter(Mandatory)][Security.AccessControl.FileSystemSecurity]$Acl)
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $replace=[long][Security.AccessControl.FileSystemRights]'DeleteSubdirectoriesAndFiles,Delete,ChangePermissions,TakeOwnership'
    foreach($rule in $Acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($rule.AccessControlType -ne 'Allow' -or ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)){continue}
        if($rule.IdentityReference.Value -notin $trusted -and (([long]$rule.FileSystemRights -band ($replace -bor 0x10000000L)))){throw 'PSM TLS backup ancestor permits untrusted replacement or ACL modification'}
    }
}
function Assert-PASeasyPsmTlsBackupTrusted {
    param([string]$BackupPath=(Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp\InstallationAutomation-RestoreTLSSettings.reg'))
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if(([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){$trusted+=$identity.User.Value}
    $cursor=[IO.Path]::GetFullPath($BackupPath)
    while($cursor){
        $item=$null
        try{$item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop}
        catch [System.Management.Automation.ItemNotFoundException]{
            # A dangling/reparse entry must not be confused with a missing filename.
            $parent=Split-Path $cursor -Parent
            if($parent -and (Test-Path -LiteralPath $parent)){
                $leaf=Split-Path $cursor -Leaf
                if(@([IO.Directory]::EnumerateFileSystemEntries($parent)|Where-Object {[IO.Path]::GetFileName($_) -ieq $leaf}).Count){throw 'PSM TLS backup has an unresolved directory entry'}
            }
        }
        if($item){
            if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'PSM TLS backup has a reparse ancestor'}
            $acl=Get-Acl -LiteralPath $cursor
            if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'PSM TLS backup has an untrusted owner or ancestor'}
            if($cursor -eq [IO.Path]::GetFullPath($BackupPath)){
                if($item.PSIsContainer){throw 'PSM TLS backup must be a regular file'}
                $write=[Security.AccessControl.FileSystemRights]'Write,Delete,ChangePermissions,TakeOwnership'
                foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
                    if($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly){continue}
                    if($rule.AccessControlType -eq 'Allow' -and (([long]$rule.FileSystemRights -band ([long]$write -bor 0x50000000L))) -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $trusted){throw 'PSM TLS backup permits an untrusted writer'}
                }
                Assert-PASeasyPsmTlsBackupData -Path $cursor
            }else{Assert-PASeasyPsmAncestorAcl -Acl $acl}
        }
        $next=Split-Path $cursor -Parent;if($next -eq $cursor){break};$cursor=$next
    }
}
function Assert-PASeasyPsmTlsRestored {
    $base='HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols'
    foreach($protocol in @('TLS 1.0','TLS 1.1','TLS 1.2')){
        $enabled=if($protocol -eq 'TLS 1.2'){1}else{0}
        $disabled=1-$enabled
        foreach($role in @('Client','Server')){
            $key=Join-Path (Join-Path $base $protocol) $role
            $value=Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            if($value.Enabled -isnot [int] -or $value.DisabledByDefault -isnot [int] -or $value.Enabled -ne $enabled -or $value.DisabledByDefault -ne $disabled){throw 'PSM TLS registry postcondition failed: legacy protocols must be disabled and TLS 1.2 enabled for client and server'}
        }
    }
}
function Assert-PASeasyPsmRdpTransport {
    # The native v15 DisableNLA prerequisite is required by ticket-based generated RDP files.
    # Require TLS independently; the vendor optional SecurityLayer=1 downgrade is not needed.
    $listener=@(Get-CimInstance -Namespace 'root/cimv2/terminalservices' -ClassName Win32_TSGeneralSetting -Filter "TerminalName='RDP-tcp'" -ErrorAction Stop)
    if($listener.Count -ne 1 -or $listener[0].UserAuthenticationRequired -ne 0 -or $listener[0].SecurityLayer -ne 2 -or $listener[0].MinEncryptionLevel -notin @(3,4)){throw 'PSM RDP transport requires the vendor NLA-disabled prerequisite and TLS security layer 2'}
}
function Set-PASeasyPsmRdpTls {
    # RDS/native setup can reset the listener to Negotiate after prerequisites.
    # Require TLS after the last native stage; keep the vendor ticket NLA prerequisite intact.
    $listener=@(Get-CimInstance -Namespace 'root/cimv2/terminalservices' -ClassName Win32_TSGeneralSetting -Filter "TerminalName='RDP-tcp'" -ErrorAction Stop)
    if($listener.Count -ne 1 -or $listener[0].UserAuthenticationRequired -ne 0){throw 'PSM ticket NLA prerequisite must complete before securing the RDP listener'}
    if($listener[0].MinEncryptionLevel -notin @(3,4)){throw 'PSM RDP listener requires high or FIPS encryption before TLS configuration'}
    if($listener[0].SecurityLayer -ne 2){
        $result=Invoke-CimMethod -InputObject $listener[0] -MethodName SetSecurityLayer -Arguments @{SecurityLayer=[uint32]2} -ErrorAction Stop
        if($null -eq $result -or -not $result.PSObject.Properties['ReturnValue']){throw 'PSM RDP listener TLS configuration returned an unknown method result'}
        # Server2022's actual TS provider returns an explicit null ReturnValue even on
        # applied updates (also through classic WMI). Never invent a numeric success.
        # An omitted numeric code requires the same strict independent state readback.
        if($null -ne $result.ReturnValue -and (($result.ReturnValue -isnot [uint32] -and $result.ReturnValue -isnot [int]) -or $result.ReturnValue -ne 0)){throw 'PSM RDP listener TLS configuration failed; native method did not return success'}
    }
    Assert-PASeasyPsmRdpTransport
}
function Get-PASeasyPsmTempRules {
    param([Security.AccessControl.DirectorySecurity]$Acl)
    $trusted=@('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $create=[long][Security.AccessControl.FileSystemRights]'CreateFiles,CreateDirectories'
    $critical=[long][Security.AccessControl.FileSystemRights]'DeleteSubdirectoriesAndFiles,Delete,ChangePermissions,TakeOwnership'
    $write=[long][Security.AccessControl.FileSystemRights]'Write,Delete,ChangePermissions,TakeOwnership'
    $genericWrite=[long]0x50000000
    $safe=[long][Security.AccessControl.FileSystemRights]'ReadAndExecute,ReadPermissions,Synchronize,ReadAttributes'
    $changes=@()
    foreach($rule in $Acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($rule.AccessControlType -ne 'Allow'){continue}
        $sid=$rule.IdentityReference.Value
        if($sid -in $trusted){continue}
        $io=[bool]($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)
        if($sid -eq 'S-1-3-0' -and $io){continue}
        $rights=([long]$rule.FileSystemRights -band 0xFFFFFFFFL)
        if(($rule.InheritanceFlags -band [Security.AccessControl.InheritanceFlags]::ObjectInherit) -and ($rights -band ($write -bor $genericWrite))){throw 'PSM vendor temp directory grants untrusted inherited file writes; explicit security remediation required'}
        if($io){continue}
        if($rights -band ($critical -bor $genericWrite)){throw 'PSM vendor temp directory grants untrusted delete or ACL rights; explicit security remediation required'}
        if(-not ($rights -band $create) -and ($rights -band $write)){throw 'PSM vendor temp directory has noncanonical write grants; explicit security remediation required'}
        if($rights -band $create){
            if($rule.IsInherited -or $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None -or ($rights -band (-bnot ($create -bor $safe)))){throw 'PSM vendor temp directory has noncanonical creation rights; explicit security remediation required'}
            $changes+=,$rule
        }
    }
    return $changes
}
function Assert-PASeasyPsmTempDirectory {
    param([string]$DirectoryPath=(Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp'))
    $item=Get-Item -LiteralPath $DirectoryPath -Force -ErrorAction Stop
    if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'PSM vendor temp directory must be a regular directory'}
    $acl=Get-Acl -LiteralPath $DirectoryPath -ErrorAction Stop
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')){throw 'PSM vendor temp directory has an untrusted owner'}
    if(@(Get-PASeasyPsmTempRules $acl).Count){throw 'PSM vendor temp directory permits untrusted root creation'}
}
function Protect-PASeasyPsmTempDirectory {
    param([Parameter(Mandatory)][string]$AuditRoot,[string]$DirectoryPath=(Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp'))
    $item=Get-Item -LiteralPath $DirectoryPath -Force -ErrorAction Stop
    if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'PSM vendor temp directory must be a regular directory'}
    $acl=Get-Acl -LiteralPath $DirectoryPath -ErrorAction Stop
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -notin @('S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')){throw 'PSM vendor temp directory has an untrusted owner'}
    $changes=@(Get-PASeasyPsmTempRules $acl)
    if(-not $changes.Count){Assert-PASeasyPsmTempDirectory $DirectoryPath;return}
    $access=[Security.AccessControl.AccessControlSections]::Access
    $before=$acl.GetSecurityDescriptorSddlForm($access)
    $updated=[Security.AccessControl.DirectorySecurity]::new()
    $updated.SetSecurityDescriptorSddlForm($before,$access)
    foreach($rule in $changes){
        $updated.RemoveAccessRuleSpecific($rule)
        if($rule.InheritanceFlags -ne [Security.AccessControl.InheritanceFlags]::None){
            $updated.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($rule.IdentityReference,$rule.FileSystemRights,$rule.InheritanceFlags,[Security.AccessControl.PropagationFlags]::InheritOnly,$rule.AccessControlType))
        }
        $remaining=([long]$rule.FileSystemRights -band (-bnot [long][Security.AccessControl.FileSystemRights]'CreateFiles,CreateDirectories'))
        if($remaining){$updated.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($rule.IdentityReference,[Security.AccessControl.FileSystemRights]$remaining,[Security.AccessControl.InheritanceFlags]::None,[Security.AccessControl.PropagationFlags]::None,$rule.AccessControlType))}
    }
    # Audit before mutation. This security control persists across reboot/controller failure;
    # no fragile temporary ACL restoration or vendor source modification is involved.
    New-Item -Path $AuditRoot -ItemType Directory -Force -ErrorAction Stop|Out-Null
    $audit=Join-Path $AuditRoot ('vendor-temp-policy-'+[guid]::NewGuid().ToString('N')+'.json')
    $record=@{utc=[datetime]::UtcNow.ToString('o');directory=$DirectoryPath;action='Restrict only untrusted temp-root creation; preserve child inheritance and traversal';beforeAccessSddl=$before;requestedAccessSddl=$updated.GetSecurityDescriptorSddlForm($access)}|ConvertTo-Json -Depth 4
    $stream=[IO.FileStream]::new($audit,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes($record);$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    Set-Acl -LiteralPath $DirectoryPath -AclObject $updated -ErrorAction Stop
    Assert-PASeasyPsmTempDirectory $DirectoryPath
    Write-Information 'PSM security control: untrusted WindowsTemp root creation restricted; child permissions preserved' -InformationAction Continue
}
function Invoke-PASeasyPsmStage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Prerequisites','Install','Register','Harden','PostInstall')][string]$Stage,
          [Parameter(Mandatory)][hashtable]$Settings,[string]$VaultPassword='')
    $ErrorActionPreference='Stop'
    Assert-PASeasyPsmNoInteractiveContinuation
    if([IO.Path]::GetFullPath([string]$env:windir).TrimEnd('\') -ine ([Environment]::GetFolderPath('Windows')).TrimEnd('\')){throw 'PSM refuses a redirected Windows directory environment'}
    Assert-PASeasyPsmTlsBackupTrusted
    $payload=Join-Path ([string]$Settings.StageRoot) 'payload'
    $markers=Join-Path ([string]$Settings.StageRoot) 'stage'
    $options=$Settings.Options;if(-not $options){$options=@{}}
    $vendorStage=@{Prerequisites='Prerequisites';Install='Installation';Register='Registration';Harden='Hardening';PostInstall='PostInstallation'}[$Stage]
    $scripts=@(Get-ChildItem -LiteralPath $payload -Recurse -File -Filter 'Execute-Stage.ps1')
    if($scripts.Count -ne 1){throw 'Expected exactly one PSM Execute-Stage.ps1 in the selected archive'}
    $command=$scripts[0].FullName
    $xmlPath=Join-Path (Split-Path -Parent $command) ($vendorStage+'\'+$vendorStage+'Config.xml')
    if(-not(Test-Path -LiteralPath $xmlPath -PathType Leaf)){throw "PSM vendor configuration missing for $Stage"}
    $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    $previous=@{Install='Prerequisites';Register='Install';Harden='Register';PostInstall='Harden'}[$Stage]
    if($previous){
        $priorPath=Join-Path $markers ($previous+'.json')
        if(-not(Test-Path -LiteralPath $priorPath)){throw "PSM $Stage requires verified $previous stage"}
        $prior=Get-Content -LiteralPath $priorPath -Raw | ConvertFrom-Json
        if($prior.restartRequired){throw "PSM $previous requires a controller-confirmed reboot and stage continuation before $Stage"}
    }
    $marker=Join-Path $markers ($Stage+'.json')
    $restartCount=0
    if(Test-Path -LiteralPath $marker){
        $saved=Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        if($saved.schemaVersion -ne 2 -or $saved.stage -ne $Stage){throw 'Unrecognized PSM stage checkpoint; reconcile before retry'}
        if(-not $saved.restartRequired){
            return [pscustomobject]@{Changed=$false;Data=@{RebootRequired=$false};Message="PSM $Stage already completed; no repeated vendor launch"}
        }
        if($saved.bootUtc -eq $boot){throw "PSM $Stage requires a controller-confirmed reboot before continuation"}
        $restartCount=[int]$saved.restartCount
        if($restartCount -ge 3){throw "PSM $Stage exceeded three vendor-requested reboots; manual reconciliation required"}
        # This is the documented vendor delayed-restart continuation, not a retry of unknown work:
        # the previous attempt completed successfully, explicitly requested reboot, and boot changed.
    }
    $xml=[xml](Get-Content -LiteralPath $xmlPath -Raw)
    $parameters=@{}
    if($Stage -eq 'Install'){
        foreach($row in @(@('installDirectory','InstallationDirectory'),@('recordingDirectory','RecordingDirectory'))){
            if($options.Contains($row[0])){$parameters[$row[1]]=[string]$options[$row[0]]}
        }
    }
    if($Stage -eq 'Register'){
        if(-not $VaultPassword){throw 'PSM registration requires the VaultAdmin secret'}
        $parameters=@{vaultip=[string]$Settings.VaultAddress;vaultusername=[string]$Settings.VaultUser;vaultport='1858';accepteula='yes'}
        if($options.Contains('vaultPort')){$parameters.vaultport=[string]$options.vaultPort}
        foreach($name in @('registerpsmwithdomain','psmuserssuffix','apigwhost','apigwprotocol','usepkiauthentication','enablePSMForWindowsAndTicketingIntegration','useVaultTLSProtocol')){
            if($options.Contains($name)){$parameters[$name]=[string]$options[$name]}
        }
    }
    foreach($name in $parameters.Keys){
        $nodes=@($xml.SelectNodes('//Parameter') | Where-Object {$_.GetAttribute('Name') -ceq $name})
        if($nodes.Count -ne 1){throw "PSM vendor XML parameter absent or ambiguous: $name"}
        $nodes[0].SetAttribute('Value',$parameters[$name])
    }
    if($Stage -eq 'Harden'){
        $outOfDomain=@($xml.SelectNodes('//Step') | Where-Object {$_.GetAttribute('Name') -ceq 'OutOfDomainHardening'})
        if($outOfDomain.Count -ne 1){throw 'PSM OutOfDomainHardening vendor step absent or ambiguous'}
        $joined=[bool](Get-CimInstance Win32_ComputerSystem).PartOfDomain
        $outOfDomain[0].SetAttribute('Enable',$(if($joined){'No'}else{'Yes'}))
    }
    if($parameters.Count -or $Stage -eq 'Harden'){$xml.Save($xmlPath)}
    if($Stage -eq 'Harden' -and -not [bool]$Settings.ApplyHardening){throw 'PSM hardening waiver must be handled by the scoped policy, not marked as vendor success'}
    Protect-PASeasyPsmTempDirectory -AuditRoot $markers
    Assert-PASeasyPsmTlsBackupTrusted
    $arguments=@{configFilePath=$xmlPath;silentMode='Silent';displayJson=$true;delayedrestart=$true;restartAfterStageCompleted=$true}
    if($Stage -eq 'Register'){$arguments.spwdObj=ConvertTo-SecureString -String $VaultPassword -AsPlainText -Force}
    $invoke=@{ScriptPath=$command;Parameters=$arguments}
    # v15 WMIC emits empty stderr even with ReturnValue=0; retain all substantive error gates.
    if($Stage -in @('Harden','PostInstall')){$invoke.AllowEmptyNativeStderr=$true;$invoke.AllowPinnedRegImportSuccess=$true}
    try {$result=Invoke-VendorScript @invoke}
    finally {
        $arguments.Remove('spwdObj');$VaultPassword=$null
        # A failed vendor result must not leave interactive credential continuation unnoticed.
        Assert-PASeasyPsmNoInteractiveContinuation
    }
    Assert-PASeasyPsmTempDirectory
    if($null -eq $result.PSObject.Properties['restartRequired']){throw 'PSM vendor result lacks restartRequired; cannot schedule safe continuation'}
    if($result.restartRequired -isnot [bool]){throw 'PSM vendor restartRequired must be a JSON boolean'}
    $restart=$result.restartRequired
    if($Stage -eq 'PostInstall'){Set-PASeasyPsmRdpTls}
    if($Stage -in @('Harden','PostInstall')){Assert-PASeasyPsmTlsRestored}
    New-Item -Path $markers -ItemType Directory -Force | Out-Null
    $record=@{schemaVersion=2;restartCount=($restartCount+$(if($restart){1}else{0}));stage=$Stage;vendorStage=$vendorStage;utc=[DateTime]::UtcNow.ToString('o');bootUtc=$boot;restartRequired=$restart;configSha256=(Get-FileHash -LiteralPath $xmlPath -Algorithm SHA256).Hash;message='Vendor stage succeeded; controller owns reboot continuation'}
    $temp=$marker+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,($record|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    if([IO.File]::Exists($marker)){[IO.File]::Replace($temp,$marker,[NullString]::Value)}else{[IO.File]::Move($temp,$marker)}
    return [pscustomobject]@{Changed=$true;Data=@{RebootRequired=$restart};Message="PSM $Stage checkpoint completed; restartRequired=$restart; controller owns continuation"}
}

function Invoke-PASeasyPsmVerify {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Stage,[Parameter(Mandatory)][hashtable]$Settings)
    $root=[string]$Settings.StageRoot
    $issues=@();$evidence=@()
    $stageNames=@{Prerequisites='Prerequisites';Install='Installation';Register='Registration';Harden='Hardening';PostInstall='PostInstallation'}
    if($Stage -eq 'Preflight'){
        $passed=Test-Path -LiteralPath ([string]$Settings.MediaTarget) -PathType Leaf
        return [pscustomobject]@{Passed=$passed;Message='PSM media preflight';Evidence=@('Media existence only')}
    }
    if($Stage -eq 'Extract'){
        $scripts=@(Get-ChildItem -LiteralPath (Join-Path $root 'payload') -Filter 'Execute-Stage.ps1' -Recurse -File -ErrorAction SilentlyContinue)
        return [pscustomobject]@{Passed=($scripts.Count -eq 1);Message='PSM vendor automation located';Evidence=@('Exactly one Execute-Stage.ps1 required')}
    }
    $checkStage=if($Stage -eq 'Verify'){'PostInstall'}else{$Stage}
    if(-not $stageNames.Contains($checkStage)){throw "Unsupported PSM verification stage $Stage"}
    $marker=Join-Path (Join-Path $root 'stage') ($checkStage+'.json')
    if(-not(Test-Path -LiteralPath $marker -PathType Leaf)){
        return [pscustomobject]@{Passed=$false;Message="PSM $checkStage checkpoint absent";Evidence=@()}
    }
    $record=Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
    if($record.schemaVersion -ne 2 -or $record.stage -ne $checkStage){$issues+='Unrecognized PSM checkpoint'}
    if($record.restartRequired -isnot [bool]){$issues+='Invalid PSM reboot evidence type'}
    $scripts=@(Get-ChildItem -LiteralPath (Join-Path $root 'payload') -Filter 'Execute-Stage.ps1' -Recurse -File -ErrorAction SilentlyContinue)
    if($scripts.Count -ne 1){$issues+='PSM automation absent or ambiguous'}else{
        $xml=Join-Path $scripts[0].DirectoryName ($stageNames[$checkStage]+'\'+$stageNames[$checkStage]+'Config.xml')
        if(-not(Test-Path -LiteralPath $xml) -or (Get-FileHash -LiteralPath $xml -Algorithm SHA256).Hash -ne $record.configSha256){$issues+='PSM vendor configuration changed after checkpoint'}
    }
    if($record.restartRequired){
        if($Stage -eq 'Verify'){$issues+='PSM post-install still requires reboot and continuation'}
        $evidence+='Vendor checkpoint succeeded; reboot and same-stage continuation remain required; installation not yet proven'
    }elseif($Stage -in @('Install','Verify')){
        $services=@(Get-Service -ErrorAction SilentlyContinue | Where-Object {$_.Name -match 'Cyber-?Ark.*(PSM|Privileged Session Manager)' -or $_.DisplayName -match 'Cyber-?Ark.*(PSM|Privileged Session Manager)'})
        if(-not $services.Count){$issues+='PSM service absent'}
        if($Stage -eq 'Verify'){
            if(@($services|Where-Object {$_.Status -ne 'Running'}).Count){$issues+='PSM service not running'}
            foreach($name in @('PSMConnect','PSMAdminConnect')){if(-not(Get-LocalUser -Name $name -ErrorAction SilentlyContinue)){$issues+="PSM local user absent: $name"}}
        }
        $evidence+=@($services | ForEach-Object {$_.Name+'='+$_.Status})
    }
    if($Stage -in @('Harden','PostInstall','Verify')){
        try {Assert-PASeasyPsmTlsRestored;$evidence+='TLS registry: legacy protocols disabled; TLS 1.2 enabled; reboot state checked separately'}catch{$issues+='PSM TLS registry restoration not confirmed'}
    }
    try{Assert-PASeasyPsmTempDirectory;$evidence+='Vendor temp root creation restricted; child permissions preserved'}catch{$issues+='PSM vendor temp root isolation not confirmed'}
    if($Stage -eq 'Verify'){try{Assert-PASeasyPsmRdpTransport;$evidence+='PSM ticket RDP listener: NLA disabled per vendor prerequisite; TLS layer 2 required'}catch{$issues+='PSM ticket RDP transport prerequisite not confirmed'}}
    $state=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    if($state -and $state.PSObject.Properties['DefaultPassword']){$issues+='Plaintext Winlogon continuation present'}
    $runOnce=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' -ErrorAction SilentlyContinue
    if($runOnce -and @($runOnce.PSObject.Properties | Where-Object {$_.Value -is [string] -and $_.Value -match 'InstallationAutomationRecovery\.ps1'}).Count){$issues+='Interactive vendor recovery continuation present'}
    $evidence+='Functional PSM connection is a separate qualification gate'
    return [pscustomobject]@{Passed=($issues.Count -eq 0);Message=($issues -join '; ');Evidence=$evidence}
}
