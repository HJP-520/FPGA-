@echo off
REM =====================================================================
REM  Headless SRAM burn: diag_hdmi_colorbar_1280x720.bit（彩条自检）
REM  用途：只验证"板子→显示器"链路（不带摄像头因素）。
REM =====================================================================
setlocal
set "BIT=%~dp0diag_hdmi_colorbar_1280x720.bit"
set "TD_BIN=D:\TD6.2.1\bin"
set "TCL=%TEMP%\bw_burn_colorbar.tcl"
set "OUT=%TEMP%\bw_burn_colorbar_out.txt"

if not exist "%BIT%" ( echo [ERROR] bit file not found: %BIT% & pause & exit /b 1 )

echo [INFO] bit file : %BIT%
certutil -hashfile "%BIT%" MD5

netstat -ano | findstr ":5555" | findstr LISTENING >nul
if errorlevel 1 (
  echo [INFO] no hwserver on port 5555, starting one...
  start "" "%TD_BIN%\hwserver.exe" -r
  timeout /t 3 /nobreak >nul
  netstat -ano | findstr ":5555" | findstr LISTENING >nul
  if errorlevel 1 ( echo [ERROR] hwserver failed to start - check cable/driver & pause & exit /b 1 )
)

>  "%TCL%" echo connect_cable -host_name 127.0.0.1:5555 -open
>> "%TCL%" echo download -bit "%BIT%"

"%TD_BIN%\bw_commands_prompt.exe" "%TCL%" > "%OUT%" 2>&1
type "%OUT%"
findstr /C:"PRG-2014" "%OUT%" >nul
if errorlevel 1 ( echo. & echo [ERROR] burn FAILED (no chip-validation line above) & pause & exit /b 1 )

echo.
echo [DONE] Colorbar pattern should be on the display now.
pause
