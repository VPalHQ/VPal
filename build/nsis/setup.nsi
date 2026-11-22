; VPal-Setup.exe: puts VPal in a folder you pick (C:\VPal by default). No administrator rights needed.
; The control panel then sets up the Palworld server itself the first time it opens.
Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"

!define APP "VPal Server Command Center"
!define VER "0.6.1"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\VPal"

Name "${APP}"
OutFile "..\VPal-Setup.exe"
InstallDir "C:\VPal"
RequestExecutionLevel user
SetCompressor /SOLID lzma
BrandingText "VPal ${VER} (beta). Unofficial, not affiliated with Pocketpair."
VIProductVersion "0.6.1.0"
VIAddVersionKey "ProductName" "${APP}"
VIAddVersionKey "FileDescription" "${APP} setup"
VIAddVersionKey "FileVersion" "${VER}"
VIAddVersionKey "ProductVersion" "${VER}"
VIAddVersionKey "LegalCopyright" "Unofficial fan tool, not affiliated with Pocketpair"

!define MUI_ICON "..\vpal.ico"
!define MUI_UNICON "..\vpal.ico"
!define MUI_ABORTWARNING

!define MUI_WELCOMEPAGE_TITLE "Set up ${APP}"
!define MUI_WELCOMEPAGE_TEXT "VPal is a free control panel for a Palworld dedicated server on this PC: settings, players, backups, a watchdog that restarts the server after a crash, a Discord bot and the Pal Planner.$\r$\n$\r$\nThis setup puts VPal in a folder. When VPal opens, it asks a few questions and downloads the free Palworld server from Steam (about 6 GB).$\r$\n$\r$\nVPal is an unofficial fan tool. It is not made by or affiliated with Pocketpair."
!insertmacro MUI_PAGE_WELCOME

!define MUI_PAGE_HEADER_TEXT "What VPal installs"
!define MUI_PAGE_HEADER_SUBTEXT "Everything VPal puts on this PC or changes, and the parts made by others."
!define MUI_LICENSEPAGE_TEXT_TOP "Please read this. Nothing here is hidden or runs without you knowing."
!define MUI_LICENSEPAGE_TEXT_BOTTOM "Click Next to continue."
!define MUI_LICENSEPAGE_BUTTON "&Next >"
!insertmacro MUI_PAGE_LICENSE "..\files\NOTICE.txt"

!define MUI_DIRECTORYPAGE_TEXT_TOP "Pick the folder for VPal and the Palworld server (about 7 GB with worlds and backups). A short folder like C:\VPal works best.$\r$\n$\r$\nAlready have a Palworld dedicated server? Pick its folder (the one with PalServer.exe) and VPal uses that server."
!define MUI_PAGE_CUSTOMFUNCTION_LEAVE CheckFolder
!insertmacro MUI_PAGE_DIRECTORY

!insertmacro MUI_PAGE_INSTFILES

!define MUI_FINISHPAGE_TITLE "VPal is installed"
!define MUI_FINISHPAGE_TEXT "Open VPal from the desktop or the Start menu. The first time, it asks a few questions and sets up the server."
!define MUI_FINISHPAGE_RUN "$INSTDIR\VPal.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Open VPal now"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

Var PS

!macro FindPowerShell
  StrCpy $PS "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  ${If} ${RunningX64}
    StrCpy $PS "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  ${EndIf}
!macroend

Function CheckFolder
  ; the folder must be one this Windows account can write to (Program Files and Windows are not)
  ClearErrors
  CreateDirectory "$INSTDIR"
  FileOpen $0 "$INSTDIR\vpal-write-test.tmp" w
  ${If} ${Errors}
    MessageBox MB_ICONEXCLAMATION "VPal can't write to $INSTDIR.$\r$\n$\r$\nPick a folder you can write to, like C:\VPal."
    Abort
  ${EndIf}
  FileClose $0
  Delete "$INSTDIR\vpal-write-test.tmp"
  RMDir "$INSTDIR"   ; only removes it if empty; setup makes it again
FunctionEnd

Section "VPal" SecMain
  !insertmacro FindPowerShell
  InitPluginsDir
  ; an older VPal's watchdog holds one of its files open, so stop it first (VPal starts it again)
  File /oname=$PLUGINSDIR\stop-vpal.ps1 "stop-vpal.ps1"
  DetailPrint "Pausing VPal's watchdog if it is running..."
  nsExec::Exec '"$PS" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\stop-vpal.ps1"'
  Pop $0

  SetOutPath "$INSTDIR"
  File "..\files\VPal.exe"
  File "..\files\PalworldSettingsEditor.ps1"
  File "..\files\NOTICE.txt"
  SetOutPath "$INSTDIR\CommandCenter"
  File /r "..\files\CommandCenter\*.*"
  SetOutPath "$INSTDIR\PalPlanner"
  File /r "..\files\PalPlanner\*.*"
  SetOutPath "$INSTDIR"

  CreateShortcut "$DESKTOP\VPal Server Command Center.lnk" "$INSTDIR\VPal.exe" "" "$INSTDIR\VPal.exe" 0
  CreateDirectory "$SMPROGRAMS\VPal"
  CreateShortcut "$SMPROGRAMS\VPal\VPal Server Command Center.lnk" "$INSTDIR\VPal.exe" "" "$INSTDIR\VPal.exe" 0
  CreateShortcut "$SMPROGRAMS\VPal\Uninstall VPal.lnk" "$INSTDIR\Uninstall VPal.exe"

  WriteUninstaller "$INSTDIR\Uninstall VPal.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "${APP}"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VER}"
  WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "VPal (unofficial Palworld fan tool)"
  WriteRegStr HKCU "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\VPal.exe"
  WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall VPal.exe"'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" 16000
SectionEnd

Section "Uninstall"
  !insertmacro FindPowerShell
  InitPluginsDir
  File /oname=$PLUGINSDIR\uninstall-vpal.ps1 "uninstall-vpal.ps1"
  DetailPrint "Stopping VPal and removing its scheduled tasks..."
  nsExec::Exec '"$PS" -NoProfile -ExecutionPolicy Bypass -File "$PLUGINSDIR\uninstall-vpal.ps1"'
  Pop $0

  Delete "$INSTDIR\VPal.exe"
  Delete "$INSTDIR\PalworldSettingsEditor.ps1"
  Delete "$INSTDIR\NOTICE.txt"
  RMDir /r "$INSTDIR\CommandCenter\service"
  RMDir /r "$INSTDIR\CommandCenter\data\updates"
  RMDir /r "$INSTDIR\CommandCenter\data\ui"
  Delete "$INSTDIR\CommandCenter\README.txt"
  RMDir "$INSTDIR\CommandCenter"
  RMDir /r "$INSTDIR\PalPlanner\engine"
  RMDir /r "$INSTDIR\PalPlanner\web"
  Delete "$INSTDIR\PalPlanner\README.txt"
  RMDir "$INSTDIR\PalPlanner"

  Delete "$DESKTOP\VPal Server Command Center.lnk"
  Delete "$SMPROGRAMS\VPal\VPal Server Command Center.lnk"
  Delete "$SMPROGRAMS\VPal\Uninstall VPal.lnk"
  RMDir "$SMPROGRAMS\VPal"
  DeleteRegKey HKCU "${UNINST_KEY}"
  Delete "$INSTDIR\Uninstall VPal.exe"
  RMDir "$INSTDIR"

  IfFileExists "$INSTDIR\*.*" 0 gone
    MessageBox MB_ICONINFORMATION "VPal is removed.$\r$\n$\r$\nYour Palworld server, worlds, backups and settings are still in $INSTDIR, so nothing was lost. Delete that folder yourself if you no longer need them.$\r$\n$\r$\nFirewall rules named $\"VPal Palworld...$\" stay in Windows Defender Firewall, and Tailscale (if you used it for the Pal Planner) stays in Apps, until you remove them."
  gone:
SectionEnd
