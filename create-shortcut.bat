@echo off
setlocal enabledelayedexpansion

REM --- Resolve current folder and target vbs ---
set "DIR=%~dp0"
set "VBS=%DIR%cli-proxy-api.vbs"

if not exist "%VBS%" (
  echo Not found: %VBS%
  pause
  exit /b 1
)

REM --- Desktop shortcut path ---
set "DESK=%USERPROFILE%\Desktop"
set "LNK=%DESK%\CLIProxyAPI Tray.lnk"

REM --- Create shortcut via PowerShell + WScript.Shell COM ---
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ws = New-Object -ComObject WScript.Shell; " ^
  "$s = $ws.CreateShortcut('%LNK%'); " ^
  "$s.TargetPath = 'wscript.exe'; " ^
  "$s.Arguments = '""%VBS%""'; " ^
  "$s.WorkingDirectory = '%DIR%'; " ^
  "$s.IconLocation = '%SystemRoot%\System32\shell32.dll,44'; " ^
  "$s.Save()"

if exist "%LNK%" (
  echo Shortcut created: "%LNK%"
) else (
  echo Failed to create shortcut.
)

pause
endlocal
