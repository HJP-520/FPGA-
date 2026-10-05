# msim_passthrough.do —— 视频通路整链仿真一键脚本
# 用法：在 sim 目录打开 ModelSim 控制台，执行 do msim_passthrough.do
# 或直接运行 run_sim.bat（免 GUI，命令行出结果）

# 重建 work 库(避免 vopt 缓存导致跑旧设计)
if {[file exists work]} { vdel -all }
vlib work
vmap work work

# 编译（-f 清单见 filelist_sim.f）
vlog -f filelist_sim.f

# 仿真（命令行模式，跑完自动退出）
vsim -c tb_video_passthrough -do "run -all; quit -f"
