@echo off
setlocal
set "BIT=%~1"
if not defined TD_BIN set "TD_BIN=D:\TD6.2.1\bin"
if not exist "%BIT%" (echo [ERROR] Missing bit: %BIT% & exit /b 1)
if not exist "%TD_BIN%\bw_commands_prompt.exe" (echo [ERROR] Set TD_BIN to your TD bin directory & exit /b 1)
if not exist "%TD_BIN%\hwserver.exe" (echo [ERROR] Missing hwserver & exit /b 1)
echo [BIT] %BIT%
powershell -NoProfile -Command "Get-FileHash -Algorithm SHA256 -LiteralPath $env:BIT | Format-List"
netstat -ano | findstr /R /C:":5555 .*LISTENING" >nul
if errorlevel 1 powershell -NoProfile -Command "Start-Process -FilePath ($env:TD_BIN+'\hwserver.exe') -ArgumentList '-r' -WindowStyle Hidden"
set /a TRIES=0
:wait_server
netstat -ano | findstr /R /C:":5555 .*LISTENING" >nul
if not errorlevel 1 goto server_ready
set /a TRIES+=1
if %TRIES% GEQ 20 (echo [ERROR] hwserver did not become ready & exit /b 1)
timeout /t 1 /nobreak >nul
goto wait_server
:server_ready
set "TCL=%TEMP%\sc520_codex_%RANDOM%_%RANDOM%.tcl"
set "BIT_TCL=%BIT:\=/%"
if not exist "%~dp0logs" mkdir "%~dp0logs"
set "LOG=%~dp0logs\burn_%~n1_%RANDOM%.log"
> "%TCL%" echo connect_cable -host_name 127.0.0.1:5555 -open
>> "%TCL%" echo download -bit {%BIT_TCL%}
rem TD parses the script argument as Tcl; use forward slashes on Windows.
set "TCL_ARG=%TCL:\=/%"
"%TD_BIN%\bw_commands_prompt.exe" "%TCL_ARG%" > "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
type "%LOG%"
del /q "%TCL%"
if not "%RC%"=="0" (echo [ERROR] Downloader exit code %RC%. Log: %LOG% & exit /b %RC%)
powershell -NoProfile -Command "$t=Get-Content -LiteralPath $env:LOG -Raw; if(($t -match 'PRG-2014') -and ($t -match '100\s*\x25')) {exit 0} else {exit 1}"
if errorlevel 1 (echo [ERROR] Download completion could not be verified. Log: %LOG% & exit /b 1)
echo [DONE] SRAM download completed. Verify live picture on the display.
exit /b 0
