@echo off
rem run_sim.bat —— 视频通路整链仿真一键运行（ModelSim SE 命令行）
rem 前提：ModelSim 安装于 D:\ModelSim（如不同请改下面的 VSIM_DIR）
setlocal
set VSIM_DIR=D:\ModelSim\win64
set PATH=%VSIM_DIR%;%PATH%

cd /d %~dp0
if exist work rmdir /s /q work
vlib work
vlog -f filelist_sim.f
if errorlevel 1 (
    echo ==== 编译失败，检查 filelist_sim.f ====
    exit /b 1
)
vsim -c tb_video_passthrough -do "run -all; quit -f"
echo ==== 仿真结束，转储文件 passthrough_frame_N.hex 见本目录 ====
endlocal
