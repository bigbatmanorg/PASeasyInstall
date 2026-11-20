BeforeAll {. (Join-Path $PSScriptRoot 'TestHelpers.ps1'); Import-PASTestModule; . (Get-PASTestPrivateProxy)}
Describe 'Hashtable host grouping on Windows PowerShell' {
    It 'names the actual shared host in the co-location warning' {
        $c=New-PASConfigurationTemplate -Template FullLab -Path (Join-Path $TestDrive 'shared.json') -WhatIf
        $c.components=@($c.components|Where-Object {$_.type -in @('PVWA','CPM')});$c.vault.existing=$true
        $result=Test-PASConfiguration -Configuration $c
        @($result.Warnings|Where-Object {$_ -match '^Co-located components on pam01 require'}).Count|Should -Be 1
    }
    It 'does not invent co-location between components on separate hosts' {
        $c=New-PASConfigurationTemplate -Template FullLab -Path (Join-Path $TestDrive 'separate.json') -WhatIf
        $c.components=@($c.components|Where-Object {$_.type -in @('PVWA','CPM')});$c.vault.existing=$true
        ($c.components|Where-Object type -eq CPM).host='psm01'
        @((Test-PASConfiguration -Configuration $c).Warnings|Where-Object {$_ -match '^Co-located components'}).Count|Should -Be 0
    }
}
