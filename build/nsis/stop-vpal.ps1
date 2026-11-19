# Stops VPal's background programs so their files can be replaced or removed.
# -All also stops the Pal Planner's website. Used by VPal-Setup.exe and its uninstaller.
param([switch]$All)
$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" |
    Where-Object { $_.CommandLine -like '*ccservice.py*' -or ($All -and $_.CommandLine -like '*PalPlanner*webserver.py*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Start-Sleep -Milliseconds 800
exit 0
