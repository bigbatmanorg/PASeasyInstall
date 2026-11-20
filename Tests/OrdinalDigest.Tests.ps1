BeforeDiscovery {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
}
Describe 'Platform-independent source and configuration key ordering' {
    InModuleScope PASeasyInstall.Core {
        It 'hashes the known punctuation-sensitive filename fixture in ordinal order' {
            $fixture=Join-Path $TestDrive 'source'
            $null=New-Item -Path $fixture -ItemType Directory
            foreach($name in @('VaultDR.psd1','VaultDR-Phase2.psd1','VaultDR-Phase1.psd1')){[IO.File]::WriteAllText((Join-Path $fixture $name),'fixture',[Text.UTF8Encoding]::new($false))}
            $contentHash=(Get-FileHash (Join-Path $fixture 'VaultDR.psd1') -Algorithm SHA256).Hash.ToLowerInvariant()
            # Explicit expected order, rather than a second invocation of the implementation's sorter.
            $expected=Get-PASTextDigest ((@('VaultDR-Phase1.psd1','VaultDR-Phase2.psd1','VaultDR.psd1')|ForEach-Object {$_+'='+$contentHash}) -join "`n")
            $savedRoot=$script:PASRoot;$savedCulture=[Threading.Thread]::CurrentThread.CurrentCulture
            try{
                $script:PASRoot=$fixture
                foreach($name in @('en-US','cs-CZ','tr-TR','')){
                    [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($name)
                    Get-PASSourceDigest|Should -BeExactly $expected
                }
            }finally{$script:PASRoot=$savedRoot;[Threading.Thread]::CurrentThread.CurrentCulture=$savedCulture}
        }
        It 'uses ordinal property order recursively for dictionaries and JSON objects' {
            $savedCulture=[Threading.Thread]::CurrentThread.CurrentCulture
            try{
                foreach($name in @('en-US','cs-CZ','tr-TR','')){
                    [Threading.Thread]::CurrentThread.CurrentCulture=[Globalization.CultureInfo]::GetCultureInfo($name)
                    $value=@{'VaultDR.psd1'=1;'VaultDR-Phase1.psd1'=@{'a.b'=1;'a-b'=2;'ab'=3}}
                    $dict=ConvertTo-PASCanonical $value
                    (@($dict.Keys) -join ',')|Should -BeExactly 'VaultDR-Phase1.psd1,VaultDR.psd1'
                    (@($dict['VaultDR-Phase1.psd1'].Keys) -join ',')|Should -BeExactly 'a-b,a.b,ab'
                    $object=ConvertTo-PASCanonical ($value|ConvertTo-Json -Depth 5|ConvertFrom-Json)
                    (@($object.Keys) -join ',')|Should -BeExactly 'VaultDR-Phase1.psd1,VaultDR.psd1'
                }
            }finally{[Threading.Thread]::CurrentThread.CurrentCulture=$savedCulture}
        }
    }
}
