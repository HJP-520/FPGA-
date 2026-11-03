@echo off
rem SRAM downloader for SC520. Set TD_BIN or SC520_TD_ROOT to your TD installation.
setlocal
set "BIT=%~1"
if not defined BIT (echo [ERROR] Pass a verified bit path. & exit /b 1)
if not defined TD_BIN if defined SC520_TD_ROOT set "TD_BIN=%SC520_TD_ROOT%\bin"
if not defined TD_BIN set "TD_BIN=D:\TD6.2.1\bin"
if not exist "%BIT%" (echo [ERROR] Missing bit: %BIT% & exit /b 1)
if not exist "%TD_BIN%\bw_commands_prompt.exe" (echo [ERROR] Missing bw_commands_prompt.exe under %TD_BIN% & exit /b 1)
if not exist "%TD_BIN%\hwserver.exe" (echo [ERROR] Missing hwserver.exe under %TD_BIN% & exit /b 1)

echo [BIT] %BIT%
powershell -NoProfile -Command "Get-FileHash -Algorithm SHA256 -LiteralPath $env:BIT | Format-List"

netstat -ano | findstr /R /C:":5555 .*LISTENING" >nul
if errorlevel 1 (
  echo [SRV] starting hwserver -r
  powershell -NoProfile -Command "Start-Process -FilePath ($env:TD_BIN+'\hwserver.exe') -ArgumentList '-r' -WindowStyle Hidden"
)
set /a TRIES=0
:wait_server
netstat -ano | findstr /R /C:":5555 .*LISTENING" >nul
if not errorlevel 1 goto server_ready
set /a TRIES+=1
if %TRIES% GEQ 20 (echo [ERROR] hwserver did not become ready - is the USB-JTAG cable plugged in? & exit /b 1)
ping -n 2 127.0.0.1 >nul
goto wait_server
:server_ready

set "TCL=%TEMP%\sc520_burn_%RANDOM%_%RANDOM%.tcl"
set "TCL_ARG=%TCL:\=/%"
set "BIT_TCL=%BIT:\=/%"
if not exist "%~dp0logs" mkdir "%~dp0logs"
set "LOG=%~dp0logs\burn_%~n1_%RANDOM%.log"
> "%TCL%" echo connect_cable -host_name 127.0.0.1:5555 -open
>> "%TCL%" echo download -bit {%BIT_TCL%}

"%TD_BIN%\bw_commands_prompt.exe" "%TCL_ARG%" > "%LOG%" 2>&1
set "RC=%ERRORLEVEL%"
type "%LOG%"
del /q "%TCL%" 2>nul

if not "%RC%"=="0" (echo [ERROR] Downloader exit code %RC%. Log: %LOG% & exit /b %RC%)
findstr /C:"PRG-2014" "%LOG%" >nul
if errorlevel 1 (echo [ERROR] PRG-2014 not found in log. Log: %LOG% & exit /b 1)
findstr /C:"PRG-8000" "%LOG%" >nul
if not errorlevel 1 (echo [ERROR] PRG-8000 in log - transfer did not complete. Log: %LOG% & exit /b 1)
findstr /C:"transfer failed" "%LOG%" >nul
if not errorlevel 1 (echo [ERROR] 'transfer failed' in log. Log: %LOG% & exit /b 1)
echo [DONE] SRAM download completed and verified. Log: %LOG%
exit /b 0
