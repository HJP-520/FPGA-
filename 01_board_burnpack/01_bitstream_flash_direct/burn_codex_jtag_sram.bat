@echo off
call "%~dp0burn_checked.cmd" "%~dp0camera_to_dsi_display_codex_jtag.bit"
set "RC=%ERRORLEVEL%"
pause
exit /b %RC%
