# Embedded execution internals, private to the PASeasyInstall module.
$script:PAExecRoot = $PSScriptRoot
foreach ($part in @('Common','RecipePayload','Manifest','Adapters','LinuxDetached','WindowsStaging','Detached','DurableCheck','Engine')) {
    . (Join-Path $PSScriptRoot ($part + '.ps1'))
}
