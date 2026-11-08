@echo off
REM Opens the Thermal Monitor window (live temperatures + graphs). Asks for Administrator rights.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\ThermalUI.ps1"
