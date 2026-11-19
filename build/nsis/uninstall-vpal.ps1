# Removes what VPal set up outside its folder: its scheduled tasks and the planner's startup shortcut.
# The Palworld server, worlds, backups and settings are left alone.
$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" |
    Where-Object { $_.CommandLine -like '*ccservice.py*' -or $_.CommandLine -like '*PalPlanner*webserver.py*' -or $_.CommandLine -like '*palplanner.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
foreach ($t in @('VPal Server Watchdog', 'Palworld Command Center', 'Pal Planner refresh', 'Vega Pal Planner refresh')) {
    Get-ScheduledTask -TaskName $t | Unregister-ScheduledTask -Confirm:$false
}
$startup = [Environment]::GetFolderPath('Startup')
foreach ($l in @('Pal Planner website.lnk', 'Vega Pal Planner website.lnk')) { Remove-Item -LiteralPath (Join-Path $startup $l) -Force }
exit 0
