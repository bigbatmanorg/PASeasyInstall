@{
RootModule='PASeasyInstall.UI.psm1'
ModuleVersion='2.0.0'
GUID='399aa1cb-53e7-59d6-9889-1ddd3e5577d9'
Author='PASeasyInstall'
Description='Desktop wizard for PASeasyInstall (Start-PASeasyInstall). Presentation only: it calls the public commands of the PASeasyInstall module and implements no installer logic. Intended for building CyberArk PAM labs; production use is at your own risk.'
PowerShellVersion='5.1'
CompatiblePSEditions=@('Desktop')
# The PASeasyInstall module itself is not listed: it is imported when the window starts, from the
# folder next to this module (source checkout, portable ZIP) or else as an installed module.
RequiredModules=@(@{ModuleName='NativeHTMLKit';ModuleVersion='0.1.2'})
FunctionsToExport=@('Start-PASeasyInstall')
CmdletsToExport=@()
VariablesToExport=@()
AliasesToExport=@()
}
