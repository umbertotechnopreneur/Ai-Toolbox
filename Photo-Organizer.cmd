@echo off
setlocal
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Photo-Organizer.ps1" %*
set "organizerExitCode=%errorlevel%"
if not "%organizerExitCode%"=="0" (
    echo.
    echo Photo Organizer ha segnalato un errore. Codice: %organizerExitCode%
    if "%~1"=="" pause
)
exit /b %organizerExitCode%
