@echo off
REM =====================================================================
REM  Headless SRAM burn: camera_to_dsi_display.bit（原版直通流）
REM  前置：TD6.2.1 位于 D:\TD6.2.1；FT2232 A 通道已装 WinUSB；
REM        hwserver 手动启动必须带 -r（本脚本自动处理）。
REM =====================================================================
setlocal
set "BIT=%~dp0camera_to_dsi_display.bit"
set "TD_BIN=D:\TD6.2.1\bin"
set "TCL=%TEMP%\bw_burn_sram.tcl"
set "OUT=%TEMP%\bw_burn_sram_out.txt"

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
echo [DONE] Look at the display. (SRAM load is lost on power-off.)
pause
