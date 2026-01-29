@echo off
PowerShell.exe -ExecutionPolicy Bypass -NoProfile -Command "& '%~dp0test.ps1' %*"
exit /b %ERRORLEVEL%