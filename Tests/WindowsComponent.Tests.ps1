BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/Recipes/WindowsComponent/Vendor.ps1')
    $previousWorkerAttempt=$env:PAEASY_DETACHED_ATTEMPT;$previousWorkerProcess=$env:PAEASY_DETACHED_PROCESS_ID
    $env:PAEASY_DETACHED_ATTEMPT=[guid]::NewGuid().ToString('N');$env:PAEASY_DETACHED_PROCESS_ID=[string]$PID
}
Describe 'Vendor PowerShell dispatch contract' {
    It 'binds named parameters and switches and restores caller location' {
        $path=Join-Path $TestDrive 'vendor.ps1'
        @'
param([string]$configFilePath,[switch]$displayJson,[Security.SecureString]$spwdObj)
if($configFilePath -ne 'expected.xml' -or -not $displayJson -or $null -eq $spwdObj){throw 'Wrong parameter binding'}
if(-not(Test-Path ./relative.txt)){throw 'Wrong working directory'}
@{isSucceeded=0;restartRequired=$true}|ConvertTo-Json
'@ | Set-Content $path
        Set-Content (Join-Path $TestDrive 'relative.txt') 'fixture'
        $before=(Get-Location).Path
        $result=Invoke-VendorScript $path @{configFilePath='expected.xml';displayJson=$true;spwdObj=(ConvertTo-SecureString 'marker' -AsPlainText -Force)}
        $result.restartRequired | Should -BeTrue
        (Get-Location).Path | Should -BeExactly $before
    }
    It 'rejects nonnumeric success instead of treating it as zero' {
        $path=Join-Path $TestDrive 'invalid.ps1'
        '''{"isSucceeded":"unknown"}''' | Set-Content $path
        {Invoke-VendorScript $path} | Should -Throw
    }
    It 'does not disclose raw vendor output on malformed result' {
        $path=Join-Path $TestDrive 'secret.ps1'
        "'synthetic-sensitive-marker'" | Set-Content $path
        try{Invoke-VendorScript $path;throw 'expected failure'}catch{$_.Exception.Message | Should -Not -Match 'synthetic-sensitive-marker'}
    }
}

Describe 'Explicit vendor information result channel' {
    It 'accepts CPM wrapper Write-Host JSON only when explicitly selected' {
        $path=Join-Path $TestDrive 'host-result.ps1'
        @'
Write-Host 'Vendor progress'
Write-Host '{"isSucceeded":0,"restartRequired":false}'
'@ | Set-Content $path
        {Invoke-VendorScript $path}|Should -Throw '*no structured*'
        (Invoke-VendorScript $path -ResultSource Information).isSucceeded|Should -Be 0
    }
    It 'refuses progress-only text or structured failure in information output' {
        $path=Join-Path $TestDrive 'host-failure.ps1'
        "Write-Host 'OperationSucceeded'"|Set-Content $path
        {Invoke-VendorScript $path -ResultSource Information}|Should -Throw '*no structured*'
        @'
Write-Host '{"isSucceeded":1}'
'@|Set-Content $path
        {Invoke-VendorScript $path -ResultSource Information}|Should -Throw '*Vendor stage failed*'
    }
}

Describe 'Narrow native blank stderr compatibility' {
    It 'keeps default strict and permits an empty native stderr record only with explicit switch' {
        $path=Join-Path $TestDrive 'blank-native.ps1'
        @'
cmd.exe /d /c 'echo( 1>&2'
'{"isSucceeded":0}'
'@|Set-Content $path
        $before=$ErrorActionPreference
        {Invoke-VendorScript $path}|Should -Throw
        (Invoke-VendorScript $path -AllowEmptyNativeStderr).isSucceeded|Should -Be 0
        $ErrorActionPreference|Should -Be $before
    }
    It 'refuses meaningful native stderr and restores preference without disclosing it' {
        $path=Join-Path $TestDrive 'real-native.ps1'
        @'
cmd.exe /d /c 'echo SYNTHETIC_NATIVE_ERROR_MARKER 1>&2'
'{"isSucceeded":0}'
'@|Set-Content $path
        $before=$ErrorActionPreference
        try{Invoke-VendorScript $path -AllowEmptyNativeStderr;throw 'Expected rejection'}catch{$_.Exception.Message|Should -Not -Match 'SYNTHETIC_NATIVE_ERROR_MARKER';$_.Exception.Message|Should -Match 'NativeCommandError.*real-native.ps1:[0-9]+'}
        $ErrorActionPreference|Should -Be $before
    }
    It 'refuses PowerShell errors and nonzero native exits even with compatibility switch' {
        $path=Join-Path $TestDrive 'powershell-error.ps1'
        @'
Write-Error 'SYNTHETIC_POWERSHELL_ERROR'
'{"isSucceeded":0}'
'@|Set-Content $path
        {Invoke-VendorScript $path -AllowEmptyNativeStderr}|Should -Throw '*emitted an error*'
        @'
cmd.exe /d /c 'echo( 1>&2 & exit /b 7'
'{"isSucceeded":0}'
'@|Set-Content $path
        {Invoke-VendorScript $path -AllowEmptyNativeStderr}|Should -Throw '*exited 7*'
    }
}

Describe 'Imported vendor module preference boundary' {
    It 'keeps blank native stderr from entering an imported child trap and restores script preference' {
        $dir=Join-Path $TestDrive 'module-trap';New-Item -ItemType Directory $dir|Out-Null
        @'
trap {[IO.File]::WriteAllText($env:PAEASY_VENDOR_TRAP_PROBE,'trapped');continue}
cmd.exe /d /c 'echo( 1>&2'
'@|Set-Content (Join-Path $dir 'child.ps1')
        @'
function Invoke-NestedVendor {& (Join-Path $PSScriptRoot 'child.ps1')}
Export-ModuleMember Invoke-NestedVendor
'@|Set-Content (Join-Path $dir 'nested.psm1')
        @'
Import-Module (Join-Path $PSScriptRoot 'nested.psm1') -Force
Invoke-NestedVendor
'{"isSucceeded":0}'
'@|Set-Content (Join-Path $dir 'entry.ps1')
        $vendor=Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/Recipes/WindowsComponent/Vendor.ps1'
        $harness=@'
$ErrorActionPreference='Stop'
$env:PAEASY_DETACHED_ATTEMPT=[guid]::NewGuid().ToString('N');$env:PAEASY_DETACHED_PROCESS_ID=[string]$PID
. '__VENDOR__'
$env:PAEASY_VENDOR_TRAP_PROBE=Join-Path $PSScriptRoot 'trapped.txt'
$r=Invoke-VendorScript (Join-Path $PSScriptRoot 'entry.ps1') -AllowEmptyNativeStderr
[pscustomobject]@{Succeeded=($r.isSucceeded -eq 0);Trapped=(Test-Path $env:PAEASY_VENDOR_TRAP_PROBE);Restored=($ErrorActionPreference -eq 'Stop')}|ConvertTo-Json -Compress
'@.Replace('__VENDOR__',$vendor.Replace("'","''"))
        $path=Join-Path $dir 'harness.ps1';Set-Content $path $harness
        $result=(& powershell.exe -NoProfile -File $path)|ConvertFrom-Json
        $result.Succeeded|Should -BeTrue
        $result.Trapped|Should -BeFalse
        $result.Restored|Should -BeTrue
    }
}

Describe 'Actual task-host imported module boundary' {
    It 'bounds the opt-in preference to a single task body and restores runspace global Stop' {
        $dir=Join-Path $TestDrive 'real-host-module';New-Item -ItemType Directory $dir|Out-Null
        @'
trap {[IO.File]::WriteAllText($env:PAEASY_VENDOR_TRAP_PROBE,'trapped');continue}
cmd.exe /d /c 'echo( 1>&2'
'@|Set-Content (Join-Path $dir 'child.ps1')
        @'
function Invoke-NestedVendor {& (Join-Path $PSScriptRoot 'child.ps1')}
Export-ModuleMember Invoke-NestedVendor
'@|Set-Content (Join-Path $dir 'nested.psm1')
        @'
Import-Module (Join-Path $PSScriptRoot 'nested.psm1') -Force
Invoke-NestedVendor
'{"isSucceeded":0}'
'@|Set-Content (Join-Path $dir 'entry.ps1')
        $vendor=Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/Recipes/WindowsComponent/Vendor.ps1'
        $hostFile=Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/Private/Engine/Assets/TaskHost.ps1'
        $code=@'
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
. '__VENDOR__'
$env:PAEASY_VENDOR_TRAP_PROBE='__DIR__\trapped.txt'
function Invoke-PsmLikeStage {$ErrorActionPreference='Stop';Invoke-VendorScript '__DIR__\entry.ps1' -AllowEmptyNativeStderr}
$r=Invoke-PsmLikeStage
[pscustomobject]@{Changed=$false;Message='probe';Data=@{Metadata=('Trapped='+(Test-Path $env:PAEASY_VENDOR_TRAP_PROBE)+'; Script='+$ErrorActionPreference+'; Global='+$global:ErrorActionPreference)}}
'@.Replace('__VENDOR__',$vendor.Replace("'","''")).Replace('__DIR__',$dir.Replace("'","''"))
        $codePath=Join-Path $dir 'body.txt';Set-Content $codePath $code
        $harness=@'
$global:ErrorActionPreference='Stop'
$env:PAEASY_DETACHED_ATTEMPT=[guid]::NewGuid().ToString('N');$env:PAEASY_DETACHED_PROCESS_ID=[string]$PID
$r=& '__HOST__' -Code (Get-Content '__CODE__' -Raw) -Parameters @{}
[pscustomobject]@{HostOk=$r.Ok;Metadata=$r.Terminal.Data.Metadata;Restored=($global:ErrorActionPreference -eq 'Stop')}|ConvertTo-Json -Compress
'@.Replace('__HOST__',$hostFile.Replace("'","''")).Replace('__CODE__',$codePath.Replace("'","''"))
        $path=Join-Path $dir 'harness.ps1';Set-Content $path $harness
        $r=(& powershell.exe -NoProfile -File $path)|ConvertFrom-Json
        $r.HostOk|Should -BeTrue
        $r.Metadata|Should -BeExactly 'Trapped=False; Script=Stop; Global=Stop'
        $r.Restored|Should -BeTrue
    }
}

Describe 'Compatibility context and retained failure gates' {
    It 'refuses a shared or inherited worker context before dispatch' {
        $path=Join-Path $TestDrive 'context.ps1';'''{"isSucceeded":0}'''|Set-Content $path
        $attempt=$env:PAEASY_DETACHED_ATTEMPT
        try{$env:PAEASY_DETACHED_ATTEMPT='';{Invoke-VendorScript $path -AllowEmptyNativeStderr}|Should -Throw '*dedicated*'}finally{$env:PAEASY_DETACHED_ATTEMPT=$attempt}
        $process=$env:PAEASY_DETACHED_PROCESS_ID
        try{$env:PAEASY_DETACHED_PROCESS_ID='0';{Invoke-VendorScript $path -AllowEmptyNativeStderr}|Should -Throw '*dedicated*'}finally{$env:PAEASY_DETACHED_PROCESS_ID=$process}
    }
    It 'refuses structured failure and restores global preference after a caught throw' {
        $path=Join-Path $TestDrive 'false-json.ps1';'''{"isSucceeded":1}'''|Set-Content $path
        $before=$global:ErrorActionPreference
        {Invoke-VendorScript $path -AllowEmptyNativeStderr}|Should -Throw '*Vendor stage failed*'
        $global:ErrorActionPreference|Should -Be $before
        "throw 'fixture-throw'"|Set-Content $path
        {Invoke-VendorScript $path -AllowEmptyNativeStderr}|Should -Throw '*fixture-throw*'
        $global:ErrorActionPreference|Should -Be $before
    }
}
AfterAll {
    $env:PAEASY_DETACHED_ATTEMPT=$previousWorkerAttempt
    $env:PAEASY_DETACHED_PROCESS_ID=$previousWorkerProcess
}

Describe 'Pinned PSM registry informational status' {
    BeforeEach {
        $script:pin='5CB31809DFD0A16A3AD0EBA2DCC1E1E5A1BE9121696738A0DE40CC0F3D6E21BA'
        $script:source=Join-Path $TestDrive 'InstallationCommon.ps1';Set-Content $script:source 'fixture'
        $script:record=[pscustomobject]@{FullyQualifiedErrorId='NativeCommandError';Exception=[Exception]::new('The operation completed successfully.');TargetObject='The operation completed successfully.';ErrorDetails=$null;InvocationInfo=[pscustomobject]@{ScriptName=$script:source;ScriptLineNumber=699;Line='$rc = Reg import $RegistryBackupPath'}}
        Mock Get-FileHash {@{Hash=$script:pin}}
    }
    It 'accepts only the exact native success/source/line/hash combination' {
        Test-PASeasyPinnedRegImportInfo $script:record|Should -BeTrue
        $script:record.InvocationInfo.ScriptLineNumber=700
        Test-PASeasyPinnedRegImportInfo $script:record|Should -BeFalse
        $script:record.InvocationInfo.ScriptLineNumber=699;$script:record.InvocationInfo.Line='$rc = Reg delete $RegistryBackupPath'
        Test-PASeasyPinnedRegImportInfo $script:record|Should -BeFalse
    }
    It 'accepts the reviewed 15.2.2 build of the same source (re-signed, identical code)' {
        Mock Get-FileHash {@{Hash='1E9B54FD138C590C38B346976DF822F0431E32F9157D399B041A00E6B7BDFBBB'}}
        Test-PASeasyPinnedRegImportInfo $script:record|Should -BeTrue
    }
    It 'rejects changed source hashes, other messages and PowerShell error classes' {
        Mock Get-FileHash {@{Hash=('0'*64)}}
        Test-PASeasyPinnedRegImportInfo $script:record|Should -BeFalse
        $script:record.Exception=[Exception]::new('Other native status')
        Test-PASeasyPinnedRegImportInfo $script:record|Should -BeFalse
        $script:record.Exception=[Exception]::new('The operation completed successfully.');$script:record.FullyQualifiedErrorId='WriteErrorException'
        Test-PASeasyPinnedRegImportInfo $script:record|Should -BeFalse
    }
    It 'does not bypass final failure JSON or allow this exception outside Harden and PostInstall' {
        $path=Join-Path $TestDrive 'Execute-Stage.ps1'
        @'
param($configFilePath)
Write-Error 'synthetic record'
'{"isSucceeded":1}'
'@|Set-Content $path
        Mock Test-PASeasyPinnedRegImportInfo {$true}
        {Invoke-VendorScript $path @{configFilePath='C:\fixture\Hardening\HardeningConfig.xml'} -AllowEmptyNativeStderr -AllowPinnedRegImportSuccess}|Should -Throw '*Vendor stage failed*'
        {Invoke-VendorScript $path @{configFilePath='C:\fixture\Register\RegistrationConfig.xml'} -AllowEmptyNativeStderr -AllowPinnedRegImportSuccess}|Should -Throw '*restricted*'
        @'
param($configFilePath)
'{"isSucceeded":0}'
'@|Set-Content $path
        (Invoke-VendorScript $path @{configFilePath='C:\fixture\PostInstallation\PostInstallationConfig.xml'} -AllowEmptyNativeStderr -AllowPinnedRegImportSuccess).isSucceeded|Should -Be 0
    }
}
