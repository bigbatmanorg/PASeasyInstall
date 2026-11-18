BeforeAll {
    $repo=Split-Path -Parent $PSScriptRoot
    $ownership=Get-Content (Join-Path $repo 'Modules/PASeasyInstall.Core/Recipes/WindowsComponent/Ownership.ps1') -Raw
    $workspace=Get-Content (Join-Path $repo 'Modules/PASeasyInstall.Vault/Recipes/Vault/Tasks/Common/VaultWorkspace.ps1') -Raw
    $keyCode=Get-Content (Join-Path $repo 'Modules/PASeasyInstall.Vault/Recipes/Vault/Tasks/Common/KeyGeneration.ps1') -Raw
    . ([scriptblock]::Create($ownership))
    . ([scriptblock]::Create($workspace))
    . ([scriptblock]::Create($keyCode))
    $identityCode=(Get-Command Assert-PASeasyKeyGeneratorIdentity).ScriptBlock
    function Set-KeyFixtureFile($Path,$Body){Write-PASeasyVaultOwnedFile $Path ([Text.Encoding]::UTF8.GetBytes($Body)) -CreateNew}
}
Describe 'Protected key generation publication (mocked vendor execution)' {
    BeforeEach {
        $fixture=Join-Path $env:SystemDrive ('PAeasyKeyTests-'+[guid]::NewGuid().ToString('N'))
        New-PASeasyVaultDirectory $fixture
        $settings=@{KeysDir=(Join-Path $fixture 'keys');AutomationRoot=(Join-Path $fixture 'automation')}
        New-PASeasyVaultDirectory $settings.KeysDir
        New-PASeasyVaultDirectory (Join-Path $settings.AutomationRoot 'PAKeyGen')
        Set-KeyFixtureFile (Join-Path $settings.AutomationRoot 'PAKeyGen\PAKeyGen.exe') 'SYNTHETIC_TOOL_NOT_EXECUTABLE'
        Set-KeyFixtureFile (Join-Path $settings.KeysDir 'license.xml') 'LICENSE_UNCHANGED'
        Mock Assert-PASeasyKeyGeneratorIdentity {}
        Mock Invoke-PASeasyKeyNative {
            param($Tool,$Directory)
            New-PASeasyVaultDirectory (Join-Path $Directory 'master')
            New-PASeasyVaultDirectory (Join-Path $Directory 'operator')
            foreach($name in @(Get-PASeasyKeyNames)){Set-KeyFixtureFile (Join-Path $Directory ('master\'+$name)) ('SYNTHETIC_PRIVATE_'+$name)}
        }
    }
    AfterEach {if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
    It 'publishes once, verifies a receipt, preserves license and never reruns native for trusted completion' {
        (Invoke-PASeasyKeyGeneration $settings).Changed|Should -BeTrue
        Test-PASeasyKeyReceipt $settings|Should -BeTrue
        (Invoke-PASeasyKeyGeneration $settings).Changed|Should -BeFalse
        Should -Invoke Invoke-PASeasyKeyNative -Exactly 1
        [IO.File]::ReadAllText((Join-Path $settings.KeysDir 'license.xml'))|Should -BeExactly LICENSE_UNCHANGED
        @(Get-ChildItem $settings.AutomationRoot -Directory -Filter 'PAKeyGen-attempt-*').Count|Should -Be 0
        $receipt=Get-Content (Join-Path $settings.KeysDir '.paeasy-key-generation.json') -Raw
        $receipt|Should -Not -Match SYNTHETIC_PRIVATE
    }
    It 'refuses all four preexisting unmarked keys rather than adopting them' {
        foreach($name in @(Get-PASeasyKeyNames)){Set-KeyFixtureFile (Join-Path $settings.KeysDir $name) 'unknown'}
        {Invoke-PASeasyKeyGeneration $settings}|Should -Throw '*Unmarked or partial*'
        Should -Invoke Invoke-PASeasyKeyNative -Times 0
        [IO.File]::ReadAllText((Join-Path $settings.KeysDir 'server.key'))|Should -BeExactly unknown
    }
    It 'refuses preexisting partial output without deleting it' {
        Set-KeyFixtureFile (Join-Path $settings.KeysDir 'recprv.key') 'unknown'
        {Invoke-PASeasyKeyGeneration $settings}|Should -Throw '*Unmarked or partial*'
        Should -Invoke Invoke-PASeasyKeyNative -Times 0
    }
    It 'retains interrupted-generation intent and partial workspace without retrying' {
        Mock Invoke-PASeasyKeyNative {throw 'SYNTHETIC_NATIVE_FAILURE'}
        {Invoke-PASeasyKeyGeneration $settings}|Should -Throw
        Test-Path (Join-Path $settings.KeysDir '.paeasy-key-generation.claim.json')|Should -BeTrue
        {Invoke-PASeasyKeyGeneration $settings}|Should -Throw '*intent*'
        Should -Invoke Invoke-PASeasyKeyNative -Exactly 1
    }
    It 'refuses missing native files and never publishes a false receipt' {
        Mock Invoke-PASeasyKeyNative {param($Tool,$Directory) New-PASeasyVaultDirectory (Join-Path $Directory 'master');Set-KeyFixtureFile (Join-Path $Directory 'master\server.key') 'only-one'}
        {Invoke-PASeasyKeyGeneration $settings}|Should -Throw
        Test-Path (Join-Path $settings.KeysDir '.paeasy-key-generation.json')|Should -BeFalse
        Test-Path (Join-Path $settings.KeysDir 'server.key')|Should -BeFalse
    }
    It 'rejects length/hash tamper and a transient94 owner' {
        $null=Invoke-PASeasyKeyGeneration $settings
        $file=Join-Path $settings.KeysDir 'server.key'
        [IO.File]::WriteAllText($file,'tampered')
        {Test-PASeasyKeyReceipt $settings}|Should -Throw '*differs*'
        $acl=Get-Acl $file;$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-94-1'))
        Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($file)).SetAccessControl($acl)}
        {Test-PASeasyKeyReceipt $settings}|Should -Throw '*owner*'
    }
    It 'refuses malformed receipt instead of accepting four files' {
        $null=Invoke-PASeasyKeyGeneration $settings
        [IO.File]::WriteAllText((Join-Path $settings.KeysDir '.paeasy-key-generation.json'),'{bad-json')
        {Test-PASeasyKeyReceipt $settings}|Should -Throw '*metadata*'
        {Invoke-PASeasyKeyGeneration $settings}|Should -Throw
        Should -Invoke Invoke-PASeasyKeyNative -Exactly 1
    }
    It 'does not modify old tool master or operator directories' {
        foreach($dir in @('master','operator')){New-PASeasyVaultDirectory (Join-Path $settings.AutomationRoot ('PAKeyGen\'+$dir));Set-KeyFixtureFile (Join-Path $settings.AutomationRoot ('PAKeyGen\'+$dir+'\untouched')) 'unchanged'}
        $null=Invoke-PASeasyKeyGeneration $settings
        foreach($dir in @('master','operator')){[IO.File]::ReadAllText((Join-Path $settings.AutomationRoot ('PAKeyGen\'+$dir+'\untouched')))|Should -BeExactly unchanged}
    }
    It 'refuses transient-owner tool before publishing generation intent' {
        $file=Join-Path $settings.AutomationRoot 'PAKeyGen\PAKeyGen.exe'
        $acl=Get-Acl $file;$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-94-1'))
        Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($file)).SetAccessControl($acl)}
        {Invoke-PASeasyKeyGeneration $settings}|Should -Throw '*owner*'
        Test-Path (Join-Path $settings.KeysDir '.paeasy-key-generation.claim.json')|Should -BeFalse
        Should -Invoke Invoke-PASeasyKeyNative -Times 0
    }
    It 'retains partial publication without overwriting or regenerating' {
        Mock Write-PASeasyVaultOwnedFile {throw 'Synthetic protected publication failure'} -ParameterFilter {$Path -like '*\keys\recprv.key'}
        {Invoke-PASeasyKeyGeneration $settings}|Should -Throw '*publication failure*'
        Test-Path (Join-Path $settings.KeysDir 'server.key')|Should -BeTrue
        Test-Path (Join-Path $settings.KeysDir '.paeasy-key-generation.json')|Should -BeFalse
        {Invoke-PASeasyKeyGeneration $settings}|Should -Throw '*intent*'
        Should -Invoke Invoke-PASeasyKeyNative -Exactly 1
    }
    It 'rejects a native output junction before publishing any key' {
        Mock Invoke-PASeasyKeyNative {
            param($Tool,$Directory)
            $outside=Join-Path $fixture 'outside';New-PASeasyVaultDirectory $outside
            foreach($name in @(Get-PASeasyKeyNames)){Set-KeyFixtureFile (Join-Path $outside $name) 'junction-target'}
            New-Item -Path (Join-Path $Directory 'master') -ItemType Junction -Target $outside -ErrorAction Stop|Out-Null
        }
        {Invoke-PASeasyKeyGeneration $settings}|Should -Throw '*reparse*'
        Test-Path (Join-Path $settings.KeysDir 'server.key')|Should -BeFalse
    }
    It 'rejects receipt ACL broadening without printing key material' {
        $null=Invoke-PASeasyKeyGeneration $settings
        $file=Join-Path $settings.KeysDir '.paeasy-key-generation.json'
        $acl=Get-Acl $file;$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'Read','Allow'));Set-Acl $file $acl
        {Test-PASeasyKeyReceipt $settings}|Should -Throw '*principal*'
    }
    It 'real identity assertion rejects the controller before any generation' {
        if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18'){Set-ItResult -Skipped -Because 'Requires nonSYSTEM controller';return}
        {& $identityCode}|Should -Throw '*SYSTEM*'
        Should -Invoke Invoke-PASeasyKeyNative -Times 0
    }
}
Describe 'Native keygen exit and output classification (mock process, no executable launched)' {
    BeforeEach {
        $fixture=Join-Path $env:SystemDrive ('PAeasyKeyNativeTests-'+[guid]::NewGuid().ToString('N'));New-PASeasyVaultDirectory $fixture
        $script:NativeExit=0;$script:NativeText='PAKEYGEN completed successfully';$script:NativeErr=''
        Mock Start-Process {
            param($RedirectStandardOutput,$RedirectStandardError)
            Set-KeyFixtureFile $RedirectStandardOutput $script:NativeText
            Set-KeyFixtureFile $RedirectStandardError $script:NativeErr
            $p=[pscustomobject]@{ExitCode=$script:NativeExit;HasExited=$true;Handle=[IntPtr]::new(1)}
            foreach($name in @('Refresh','Dispose')){$p|Add-Member ScriptMethod $name {}}
            $p|Add-Member ScriptMethod WaitForExit {param($ms) $true}
            $p
        }
    }
    AfterEach {if(Test-Path $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}}
    It 'requires native zero in addition to the success phrase' {
        $script:NativeExit=7
        {Invoke-PASeasyKeyNative 'C:\not-executed.exe' $fixture}|Should -Throw '*native contract*'
    }
    It 'rejects zero exit without success phrase without echoing vendor output' {
        $script:NativeText='SYNTHETIC_PRIVATE_KEY_MARKER'
        $caught=$null;try{Invoke-PASeasyKeyNative 'C:\not-executed.exe' $fixture}catch{$caught=$_.Exception.Message}
        $caught|Should -Match 'native contract'
        $caught|Should -Not -Match SYNTHETIC_PRIVATE_KEY_MARKER
        $caught|Should -Match 'stage=ValidateExitAndOutput; exit=0;'
        $caught|Should -Match 'successPhrase=False'
    }
    It 'rejects meaningful stderr and accepts only clean zero with success phrase' {
        $script:NativeErr='SYNTHETIC_PRIVATE_ERROR'
        {Invoke-PASeasyKeyNative 'C:\not-executed.exe' $fixture}|Should -Throw '*native contract*'
    }
    It 'refuses missing typed exit status even when output says success' {
        $script:NativeExit=$null
        $caught=$null;try{Invoke-PASeasyKeyNative 'C:\not-executed.exe' $fixture}catch{$caught=$_.Exception.Message}
        $caught|Should -Match 'stage=ReadExit; exit=Unavailable;'
    }
    It 'accepts clean zero with actual success phrase' {
        {Invoke-PASeasyKeyNative 'C:\not-executed.exe' $fixture}|Should -Not -Throw
    }
}

Describe 'Real harmless Windows process exit capture (no PAKeyGen execution)' {
    It 'captures true zero and nonzero exit statuses with a pinned process handle' {
        foreach($exit in @(0,7)){
            for($round=0;$round -lt 5;$round++){
                $p=Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c exit '+$exit) -PassThru -NoNewWindow
                try{
                    $handle=$p.Handle
                    $handle|Should -Not -Be ([IntPtr]::Zero)
                    $p.WaitForExit(5000)|Should -BeTrue
                    $nativeExit=$p.ExitCode
                    $nativeExit|Should -BeOfType ([int])
                    $nativeExit|Should -Be $exit
                }finally{$p.Dispose()}
            }
        }
    }
}

Describe 'Actual harmless native-wrapper execution (synthetic compiled console only)' {
    It 'accepts real zero and refuses real seven with the same success phrase' {
        $fixture=Join-Path $env:SystemDrive ('PAeasyKeyHandleQualification-'+[guid]::NewGuid().ToString('N'))
        New-PASeasyVaultDirectory $fixture
        try{
            foreach($exit in @(0,7)){
                $work=Join-Path $fixture ('exit'+$exit);New-PASeasyVaultDirectory $work
                $tool=Join-Path $work 'HarmlessExit.exe'
                $type='HarmlessKeyHandle'+[guid]::NewGuid().ToString('N')
                $code='public static class '+$type+' { public static int Main(string[] args) { System.Console.WriteLine("PAKEYGEN completed successfully."); return '+$exit+'; } }'
                Add-Type -TypeDefinition $code -Language CSharp -OutputAssembly $tool -OutputType ConsoleApplication -ErrorAction Stop
                # Protect this synthetic fixture binary; it is not vendor media.
                $acl=New-PASeasyVaultSecurity $false
                Invoke-PASeasyWithRestorePrivilege {([IO.FileInfo]::new($tool)).SetAccessControl($acl)}
                if($exit -eq 0){ {Invoke-PASeasyKeyNative $tool $work}|Should -Not -Throw }
                else{
                    $caught=$null;try{Invoke-PASeasyKeyNative $tool $work}catch{$caught=$_.Exception.Message}
                    $caught|Should -Match 'stage=ValidateExitAndOutput; exit=7;'
                    $caught|Should -Match 'successPhrase=True'
                }
            }
        }finally{Remove-Item -LiteralPath $fixture -Recurse -Force}
    }
}
