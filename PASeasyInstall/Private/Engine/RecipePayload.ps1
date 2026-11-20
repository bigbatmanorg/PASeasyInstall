# Only these shipped Vault recipes can request these static helpers. This is not
# a general include mechanism: no task-controlled path is evaluated or executed.
function Get-PASRecipePayload {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $text=[IO.File]::ReadAllText($full)
    $files=@($full)
    if($text -notmatch '(?m)^\s*# PAEASY_INCLUDE_'){return [pscustomobject]@{Text=$text;Files=$files}}
    $root=[IO.Path]::GetFullPath((Join-Path (Get-PASModuleRoot) 'Recipes/Vault'))
    $prefix=$root+[IO.Path]::DirectorySeparatorChar
    $comparison=if(Test-PASWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not $full.StartsWith($prefix,$comparison)){throw 'Static Vault helper requested outside the shipped Vault recipes'}
    $relative=$full.Substring($prefix.Length).Replace('\','/')
    $specifications=@{
        PAEASY_INCLUDE_VAULT_WORKSPACE=@{
            Tasks=@('Tasks/Common/Prepare-Paths.ps1','Tasks/Common/Verify-Paths.ps1','Tasks/Common/Expand-Media.ps1','Tasks/Common/Verify-Media.ps1')
            Helpers=@('Recipes/WindowsComponent/Ownership.ps1','Recipes/Vault/Tasks/Common/VaultWorkspace.ps1')
        }
        PAEASY_INCLUDE_VAULT_PACLI=@{
            Tasks=@('Tasks/Vault/Configure-Primary.ps1','Tasks/Vault/New-TestSafe.ps1','Tasks/Verify/Verify-Primary.ps1','Tasks/Verify/Verify-TestSafe.ps1')
            Helpers=@('Recipes/Vault/Tasks/Common/PacliTransport.ps1')
        }
        PAEASY_INCLUDE_VAULT_RDP=@{
            Tasks=@('Tasks/Vault/Harden-Vault.ps1','Tasks/Verify/Verify-Hardening.ps1')
            Helpers=@('Recipes/Vault/Tasks/Common/VaultRdp.ps1')
        }
        PAEASY_INCLUDE_VAULT_PADR=@{
            Tasks=@('Tasks/VaultDR/Configure-PADR.ps1','Tasks/VaultDR/Install-PADR.ps1','Tasks/VaultDR/Wait-Replication.ps1','Tasks/Verify/Verify-DR.ps1','Tasks/Verify/Verify-PADRInstalled.ps1')
            Helpers=@('Recipes/Vault/Tasks/Common/VaultPadr.ps1')
        }
        PAEASY_INCLUDE_VAULT_KEYS=@{
            Tasks=@('Tasks/Vault/Generate-Keys.ps1','Tasks/Verify/Verify-Keys.ps1')
            Helpers=@('Recipes/WindowsComponent/Ownership.ps1','Recipes/Vault/Tasks/Common/VaultWorkspace.ps1','Recipes/Vault/Tasks/Common/KeyGeneration.ps1')
        }
    }
    $markers=@([regex]::Matches($text,'(?m)^\s*# (PAEASY_INCLUDE_[A-Z_]+)\s*$'))
    if(-not $markers.Count){throw 'Malformed static Vault helper marker'}
    $seen=@{}
    foreach($marker in $markers){
        $name=$marker.Groups[1].Value
        if(-not $specifications.ContainsKey($name) -or $relative -cnotin $specifications[$name].Tasks -or $seen.ContainsKey($name)){throw 'Unknown, misplaced or duplicated static Vault helper marker'}
        $seen[$name]=$true
        $parts=@(foreach($helper in $specifications[$name].Helpers){
            $helperPath=Get-PASRecipePath $helper
            $files+=$helperPath
            $helperText=[IO.File]::ReadAllText($helperPath)
            if($helperText -match '(?m)^\s*# PAEASY_INCLUDE_'){throw 'Nested static Vault helpers are forbidden'}
            $helperText
        })
        # String.Replace keeps literal dollar signs and backslashes in helper code.
        $text=$text.Replace($marker.Value,("`n"+($parts -join "`n")+"`n"))
    }
    if($text -match '(?m)^\s*# PAEASY_INCLUDE_'){throw 'Unresolved static Vault helper marker'}
    return [pscustomobject]@{Text=$text;Files=@($files)}
}
