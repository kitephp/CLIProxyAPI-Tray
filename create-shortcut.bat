@echo off
setlocal

set "DIR=%~dp0"
set "INSTALLER=%DIR%install.ps1"

if not exist "%INSTALLER%" (
  echo Not found: %INSTALLER%
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%INSTALLER%"
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
  echo Failed to create shortcut. Exit code: %EXITCODE%
)

pause
exit /b %EXITCODE%
