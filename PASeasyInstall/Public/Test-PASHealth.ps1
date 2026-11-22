function Test-PASHealth {
    <#
    .SYNOPSIS
    Checks that an installed lab works: PVWA login, the components the Vault sees as connected, and DR replication.
    .DESCRIPTION
    Opens ONE authenticated PVWA REST session with the Vault Administrator credential and checks:
    - the PVWA API answers over HTTPS. The certificate is checked normally, or pinned when
      -PvwaCertificateFile is given or the configuration's CPM pins one (lab self-signed PVWA);
      when the PVWA name does not resolve on this controller, the check connects to the PVWA address
      of the configuration and sends the name, so no DNS record or hosts entry is needed;
    - which components the Vault reports as logged on (PVWA, CPM, PSM and PSMP);
    - "PASWS383E Vault is currently under maintenance mode". This usually means PVWA started before the
      Vault was up; recycle the PasswordVaultWebAccessPool app pool on the PVWA server.
    With -DRCredential it also reads the DR server's last PADR replication cycle over WinRM. With DR
    configured, component password rotation fails while DR is not replicating (CASTM057E).

    The session is serialised with running installations through the same Vault lock the installer
    uses, and is always logged off. Credentials are used in memory only and are never written anywhere.
    Nothing is changed in the lab.

    Returns Healthy, CheckedUtc, Environment, ApiBaseUri, PvwaLogin, TlsValidation, Components,
    Summary, DR, Issues and Message.
    .PARAMETER Path
    Configuration file (JSON) that installed the lab.
    .PARAMETER Configuration
    Configuration object, as returned by New-PASLabConfiguration or Import-PASLabConfiguration.
    .PARAMETER VaultCredential
    Vault Administrator (or another Vault user allowed to read system health).
    .PARAMETER ApiBaseUri
    PVWA API base, e.g. https://pvwa01/PasswordVault/API. Default: the first PVWA of the configuration.
    .PARAMETER PvwaCertificateFile
    Public certificate (.cer) of a self-signed lab PVWA to pin. The host name must still match.
    .PARAMETER DRCredential
    Windows credential of the DR server, for the replication check.
    .PARAMETER TimeoutSeconds
    Time limit of each request (10 to 600). Default 60.
    .PARAMETER DRMaxAgeMinutes
    How old the last successful DR replication may be (5 to 1440 minutes). Default 75.
    .EXAMPLE
    Test-PASHealth -Path .\MyLab.json -VaultCredential (Get-Credential Administrator)
    .EXAMPLE
    $h = Test-PASHealth -Path .\MyLab.json -VaultCredential $vault -DRCredential $dr
    $h.Components | Format-Table Component, User, Address, LoggedOn, Version
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)]
        [Alias('Config')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Configuration')]
        $Configuration,

        [Parameter(Mandatory)]
        [pscredential]$VaultCredential,

        [uri]$ApiBaseUri,

        [string]$PvwaCertificateFile = '',

        [pscredential]$DRCredential,

        [ValidateRange(10, 600)]
        [int]$TimeoutSeconds = 60,

        [ValidateRange(5, 1440)]
        [int]$DRMaxAgeMinutes = 75
    )

    $health = Resolve-PASConfigurationInput -Path $Path -Configuration $Configuration
    $health['VaultCredential'] = $VaultCredential
    $health['PvwaCertificateFile'] = $PvwaCertificateFile
    $health['TimeoutSeconds'] = $TimeoutSeconds
    $health['DRMaxAgeMinutes'] = $DRMaxAgeMinutes
    if ($ApiBaseUri) {
        $health['ApiBaseUri'] = $ApiBaseUri
    }
    if ($DRCredential) {
        $health['DRCredential'] = $DRCredential
    }
    return (Test-PASDeploymentHealth @health)
}
