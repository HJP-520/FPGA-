@echo off
setlocal
set "SRC_BIT=%~dp0..\firmware\SC520_view_manual_v17.bit"
set "EXPECTED_SHA=e0c147ed5133b1bdc336799fa405b0aab4d65b9b33572a5eb34633a473f3b020"
if not exist "%SRC_BIT%" (echo [ERROR] Missing firmware. & exit /b 1)
powershell -NoProfile -Command "if ((Get-FileHash -Algorithm SHA256 -LiteralPath $env:SRC_BIT).Hash -ne $env:EXPECTED_SHA) { exit 1 }"
if errorlevel 1 (echo [ERROR] Firmware SHA256 mismatch. & exit /b 1)
call "%~dp0burn_checked.cmd" "%SRC_BIT%"
exit /b %ERRORLEVEL%
