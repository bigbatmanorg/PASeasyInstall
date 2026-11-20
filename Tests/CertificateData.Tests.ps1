BeforeAll {
    $root=Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $root 'Modules/PASeasyInstall.Core/PASeasyInstall.Core.psd1') -Force
    $hostScript=Join-Path $root 'Modules/PASeasyInstall.Core/Private/Engine/Assets/TaskHost.ps1'
}
Describe 'Typed public certificate digests in task data' {
    It 'preserves only SHA256 strings through the target host and controller journal boundaries' {
        $code='[pscustomobject]@{Changed=$false;Message="public digests";Data=@{Hash=("a"*64);TrustBundleSHA256=("B"*64)}}'
        $result=& $hostScript -Code $code -Parameters @{}
        $result.Ok|Should -BeTrue
        $safe=& (Get-Module PASeasyInstall.Core) {param($d) Select-PASSafeData $d} $result.Terminal.Data
        $safe.Hash|Should -BeExactly ('a'*64);$safe.TrustBundleSHA256|Should -BeExactly ('B'*64)
    }
    It 'rejects arbitrary strings, numeric values and nested objects disguised as certificate digests' {
        foreach($value in @('SYNTHETIC_UNRECOGNIZED_VALUE',123,@{value=('a'*64)})){
            {& (Get-Module PASeasyInstall.Core) {param($v) Select-PASSafeData @{TrustBundleSHA256=$v}} $value}|Should -Throw
        }
        $result=& $hostScript -Code '[pscustomobject]@{Data=@{TrustBundleSHA256="not-a-hash"}}' -Parameters @{}
        $result.Ok|Should -BeFalse;$result.Terminal.Data|Should -BeNullOrEmpty
    }
}
