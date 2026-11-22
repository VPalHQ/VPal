; VPal.exe: opens the control panel (PowerShell, 64-bit, no console window).
Unicode true
!include "x64.nsh"
Name "VPal Server Command Center"
OutFile "..\files\VPal.exe"
Icon "..\vpal.ico"
RequestExecutionLevel user
SilentInstall silent
VIProductVersion "0.6.0.0"
VIAddVersionKey "ProductName" "VPal Server Command Center"
VIAddVersionKey "FileDescription" "VPal Server Command Center"
VIAddVersionKey "FileVersion" "0.6.0"
VIAddVersionKey "ProductVersion" "0.6.0"
VIAddVersionKey "LegalCopyright" "Unofficial fan tool, not affiliated with Pocketpair"

Section
  StrCpy $0 "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  ${If} ${RunningX64}
    StrCpy $0 "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  ${EndIf}
  IfFileExists "$EXEDIR\PalworldSettingsEditor.ps1" found
    MessageBox MB_ICONSTOP "The control panel file (PalworldSettingsEditor.ps1) is missing from $EXEDIR.$\r$\n$\r$\nRun VPal-Setup.exe again to repair it."
    Quit
  found:
  ExecShell "open" "$0" '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$EXEDIR\PalworldSettingsEditor.ps1"' SW_HIDE
SectionEnd
