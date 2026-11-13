@echo off
rem Opens the Alter window (uses the Windows PowerShell 5.1 that ships with Windows).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Alter.ps1"
