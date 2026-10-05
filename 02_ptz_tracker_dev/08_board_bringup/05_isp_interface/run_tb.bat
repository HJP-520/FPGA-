@echo off
rem run_tb.bat —— repack 重构单元测试（ModelSim SE 命令行）
setlocal
set VSIM_DIR=D:\ModelSim\win64
set PATH=%VSIM_DIR%;%PATH%
cd /d %~dp0
if exist work rmdir /s /q work
vlib work
vlog -f filelist_tb_repack.f
if errorlevel 1 ( echo ==== 编译失败 ==== & exit /b 1 )
vsim -c tb_repack -do "run -all; quit -f"
endlocal
