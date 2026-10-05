@echo off
REM =====================================================================
REM  [实验版] 板载 K1~K4 可调 AE/AG（A 方案）; Headless SRAM burn: 饱和度增强(K28≈1.75x) + AWB帧同步化(第1批)
REM                       + 接口修复(第2批：repack tlast/异常帧门) 版比特流
REM  构建溯源：08_board_bringup/03_td_rebuild_sat/lab_ex1_build（syn→phy 两段无头流程）
REM  验收记录：见仓库 04_awb_framesync / 05_isp_interface（单元 TB 全绿）
REM =====================================================================
setlocal
set "BIT=%~dp0camera_to_dsi_display_exp_btn.bit"
set "TD_BIN=D:\TD6.2.1\bin"
set "TCL=%TEMP%\bw_burn_sat.tcl"
set "OUT=%TEMP%\bw_burn_sat_out.txt"

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
echo [DONE] Look at the display: colors should be noticeably more saturated
echo        than the original bit, and color should be stable (no frame-top flash).
pause
