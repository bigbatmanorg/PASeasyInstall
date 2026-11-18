BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/Recipes/WindowsComponent/Workspace.ps1')
    $receiver=Join-Path (Split-Path -Parent $PSScriptRoot) 'Modules/PASeasyInstall.Core/Recipes/WindowsComponent/OwnedFileReceiver.ps1'
}
Describe 'Existing stable-file streaming receiver' {
    BeforeEach {
        $base=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $settings=@{Id='receive';StageRoot=(Join-Path $base 'components\receive');MediaTarget=(Join-Path $base 'media\receive\installer.zip');MediaSHA256=('0'*64)}
        Protect-PASeasyComponentWorkspace $settings -BaseRoot $base -PrepareTransfer
        $dest=$settings.MediaTarget
    }
    It 'streams typed chunks, checks exact length and preserves owner and hash' {
        $r=& {Write-Output -NoEnumerate ([byte[]](1,2,3));Write-Output -NoEnumerate ([byte[]](4,5))}|& $receiver -Destination $dest -ApprovedRoot $base -ExpectedLength 5
        $r.Bytes|Should -Be 5;$r.Chunks|Should -Be 2
        $r.OwnerSID|Should -BeExactly 'S-1-5-32-544'
        $r.Sha256|Should -BeExactly (Get-FileHash $dest).Hash
        [IO.File]::ReadAllBytes($dest)|Should -Be ([byte[]](1,2,3,4,5))
    }
    It 'rejects wrong chunk types and size before overwriting the existing data' {
        [IO.File]::WriteAllText($dest,'retain')
        {'not bytes'|& $receiver -Destination $dest -ApprovedRoot $base -ExpectedLength 9}|Should -Throw '*invalid byte*'
        [IO.File]::ReadAllText($dest)|Should -BeExactly 'retain'
        {Write-Output -NoEnumerate ([byte[]](1,2,3))|& $receiver -Destination $dest -ApprovedRoot $base -MaxChunkBytes 2}|Should -Throw '*invalid byte*'
    }
    It 'leaves no held handle after an interrupted producer and permits a complete retry' {
        {& {Write-Output -NoEnumerate ([byte[]](1,2));throw 'producer interrupted'}|& $receiver -Destination $dest -ApprovedRoot $base -ExpectedLength 4}|Should -Throw
        $f=[IO.File]::Open($dest,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);$f.Dispose()
        $r=Write-Output -NoEnumerate ([byte[]](8,9))|& $receiver -Destination $dest -ApprovedRoot $base -ExpectedLength 2
        $r.Bytes|Should -Be 2
        $r.OwnerSID|Should -BeExactly 'S-1-5-32-544'
    }
    It 'appends only at the approved batch offset and hashes once on finalization' {
        $r=Write-Output -NoEnumerate ([byte[]](1,2,3))|& $receiver -Destination $dest -ApprovedRoot $base -ExpectedLength 5 -Finalize $false
        $r.NextOffset|Should -Be 3;$r.Finalized|Should -BeFalse;$r.Sha256|Should -BeNullOrEmpty
        {Write-Output -NoEnumerate ([byte[]](4,5))|& $receiver -Destination $dest -ApprovedRoot $base -ExpectedLength 5 -StartOffset 2 -ExpectedPartialLength 2}|Should -Throw '*partial length*'
        $r=Write-Output -NoEnumerate ([byte[]](4,5))|& $receiver -Destination $dest -ApprovedRoot $base -ExpectedLength 5 -StartOffset 3 -ExpectedPartialLength 3
        $r.NextOffset|Should -Be 5;$r.Bytes|Should -Be 2;$r.Finalized|Should -BeTrue
        $r.Sha256|Should -BeExactly (Get-FileHash $dest).Hash
        $r.OwnerSID|Should -BeExactly 'S-1-5-32-544'
    }
    It 'restarts a known partial file from zero without changing ownership' {
        [IO.File]::WriteAllBytes($dest,[byte[]](8,8,8,8))
        $r=Write-Output -NoEnumerate ([byte[]](1,2))|& $receiver -Destination $dest -ApprovedRoot $base -ExpectedLength 2 -StartOffset 0 -ExpectedPartialLength 4
        $r.NextOffset|Should -Be 2;[IO.File]::ReadAllBytes($dest)|Should -Be ([byte[]](1,2))
    }
    It 'fails closed on missing stubs, boundary escape and expected-length mismatch' {
        {& $receiver -Destination ($dest+'.missing') -ApprovedRoot $base -ExpectedLength 0}|Should -Throw '*precreated*'
        {& $receiver -Destination $dest -ApprovedRoot (Join-Path $base 'unrelated')}|Should -Throw '*boundary*'
        {Write-Output -NoEnumerate ([byte[]](1,2))|& $receiver -Destination $dest -ApprovedRoot $base -ExpectedLength 3}|Should -Throw '*expected length*'
    }
}
