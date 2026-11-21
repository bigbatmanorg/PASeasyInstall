function Get-PASCredentialRequirement {
    <#
    .SYNOPSIS
    Lists the server accounts and passwords a lab configuration needs before it can be installed.
    .DESCRIPTION
    Returns one object per requirement with:
      Kind    Credential (an account with its password) or Secret (a password only)
      Key     the key to use in -CredentialMap or -SecretMap of Install-PASLab and Resume-PASRun
      HostId  the server id in the configuration (empty for secrets)
      User    the account name the configuration expects
      Os      Windows or Linux
      Label   a description to show when asking for it

    Secrets are VaultAdmin (Vault Administrator password), VaultMaster and DRPassword (new Vault and
    DR), ADSafeMode (new domain) and DomainJoinPassword. A Linux server is listed when the controller
    key still has to be authorised there with the password of the account.
    Nothing is contacted and nothing is asked.
    .PARAMETER Path
    Configuration file (JSON).
    .PARAMETER Configuration
    Configuration object, as returned by New-PASLabConfiguration or Import-PASLabConfiguration.
    .EXAMPLE
    Get-PASCredentialRequirement -Path .\MyLab.json | Format-Table Kind, Key, User, Label
    .EXAMPLE
    $creds = @{}
    Get-PASCredentialRequirement -Configuration $cfg | Where-Object Kind -eq 'Credential' | ForEach-Object {
        $creds[$_.Key] = Get-Credential -UserName $_.User -Message $_.Label
    }

    Collects the server accounts into a hashtable for Install-PASLab -CredentialMap.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('FullName')]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Configuration', ValueFromPipeline)]
        $Configuration
    )

    process {
        $ready = Get-PASValidatedConfiguration -Path $Path -Configuration $Configuration
        return @(Get-PASInstallRequirement -Configuration $ready)
    }
}
