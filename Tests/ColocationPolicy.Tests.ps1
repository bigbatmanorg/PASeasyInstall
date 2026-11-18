BeforeAll {Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force}
Describe 'Hashtable host grouping on Windows PowerShell' {
    It 'names the actual shared host in the co-location warning' {
        $c=New-PASeasyConfig -Template FullLab -Path (Join-Path $TestDrive 'shared.json') -WhatIf
        $c.components=@($c.components|Where-Object {$_.type -in @('PVWA','CPM')});$c.vault.existing=$true
        $result=Test-PASeasyConfig -Configuration $c
        @($result.Warnings|Where-Object {$_ -match '^Co-located components on pam01 require'}).Count|Should -Be 1
    }
    It 'does not invent co-location between components on separate hosts' {
        $c=New-PASeasyConfig -Template FullLab -Path (Join-Path $TestDrive 'separate.json') -WhatIf
        $c.components=@($c.components|Where-Object {$_.type -in @('PVWA','CPM')});$c.vault.existing=$true
        ($c.components|Where-Object type -eq CPM).host='psm01'
        @((Test-PASeasyConfig -Configuration $c).Warnings|Where-Object {$_ -match '^Co-located components'}).Count|Should -Be 0
    }
}
