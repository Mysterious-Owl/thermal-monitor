@echo off
REM Console version. Double-click = one reading.  "Start-ThermalConsole.bat watch" = keep reading.
if /I "%~1"=="watch" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\ThermalConsole.ps1" -Watch
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\ThermalConsole.ps1"
)
