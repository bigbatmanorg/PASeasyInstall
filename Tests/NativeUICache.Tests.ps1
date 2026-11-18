BeforeDiscovery {$nativeUiAvailable=[bool](Get-Module -ListAvailable NativeHTMLKit.UI)}
Describe 'Public NativeHTMLKit callback data isolation' -Skip:(-not $nativeUiAvailable) {
    BeforeAll {Import-Module NativeHTMLKit.UI -ErrorAction Stop}
    It 'keeps opaque callback data out of rendered markup and public diagnostics' {
        $ui=New-NHKUi -Title 'PASeasyInstall callback isolation'
        $private=@{Auth=@{Sentinel='SYNTHETIC_CALLBACK_ONLY_731';Password=(ConvertTo-SecureString 'SYNTHETIC_PASSWORD_642' -AsPlainText -Force)}}
        $null=Add-NHKUiButton -UI $ui -Text 'Nonsecret button label' -Data $private -OnClick {param($event,$data)}
        $html=Get-NHKUiHtml -UI $ui
        $diagnostics=Get-NHKUiDiagnostics -UI $ui | ConvertTo-Json -Depth 10
        $html | Should -Not -Match 'SYNTHETIC_CALLBACK_ONLY_731|SYNTHETIC_PASSWORD_642'
        $diagnostics | Should -Not -Match 'SYNTHETIC_CALLBACK_ONLY_731|SYNTHETIC_PASSWORD_642'
        $html | Should -Match 'Nonsecret button label'
    }
}
