from pathlib import Path
import subprocess, shutil, sys, random, os
HERE=Path(__file__).resolve().parent
MSIM=Path(os.environ.get('MODELSIM_BIN','D:/ModelSim/win64'))
B=Path(os.environ.get('SC520_RTL_ROOT',str(HERE.parent/'02_TD_project_rebuild/lab_ex1/user_source/hdl_source')))
SIM=HERE/'tests'
SIM.mkdir(exist_ok=True)
SUPPORT=HERE/'support'
for name in ['saturation_inputs.hex','saturation_expected.hex']:
    shutil.copy2(HERE/name,SIM/name)
models=[SUPPORT/'divider_gate_sim.v',SUPPORT/'ph1p_logic_eram_stub.v', B/'signal_delay.v',
                   B.parent/'ip_source/blk_mem_gen_awb_delay_signal/blk_mem_gen_awb_delay_signal.v',
                   B.parent/'ip_source/blk_mem_gen_awb_delay_signal/ram_f84573da5ab5.v']
def run(args):
    p=subprocess.run([str(a) for a in args],cwd=SIM,text=True,encoding='utf-8',errors='replace',capture_output=True,timeout=180)
    return p.returncode,p.stdout+p.stderr
code,out=run([str(MSIM/'vlib.exe'),'work'])
if os.environ.get('SC520_DEBUG_STUBS'):
    code,out=run([str(MSIM/'vlog.exe'),'-sv',os.environ['SC520_DEBUG_STUBS']])
    if code:print(out);sys.exit(code)
cases={
    'tb_repack_improved':[B/'isp/data96_128/data96_128.v',HERE/'tb_repack_improved.sv'],
    'tb_awb_improved':[B/'awb.v',*models,HERE/'tb_awb_improved.sv'],
    'tb_ae_improved':[B/'uiisp_beta/ae_set.v',HERE/'tb_ae_improved.sv'],
    'tb_fifo_recovery':[B/'video_in.v',B/'video_out.v',HERE/'tb_fifo_recovery.sv'],
    'tb_sensor_snapshot':[B/'uics520_cfg/uicfgcs520.v',B/'uics520_cfg/uics520reg_720p60.v',
                          B/'uics520_cfg/SC520GainTbl.v',B/'uics520_cfg/uics520regAE.v',HERE/'tb_sensor_snapshot.sv'],
    'tb_awb_regression':[B/'awb.v',*models,HERE/'tb_awb_regression.v'],
    'tb_saturation_improved':[B/'isp/isp_top.v',HERE/'tb_saturation_improved.sv']}
if sys.argv[1:]:
    requested=set(sys.argv[1:])
    if requested-set(cases):raise ValueError('Unknown test name')
    cases={name:files for name,files in cases.items() if name in requested}
ok=True
for top,files in cases.items():
    code,compiled=run([str(MSIM/'vlog.exe'),'-sv',*files])
    (SIM/(top+'_compile.log')).write_text(compiled,encoding='utf-8')
    if code:
        print(compiled);ok=False;continue
    code,out=run([str(MSIM/'vsim.exe'),'-c','-onfinish','exit',top,'-do','onbreak {quit -code 1 -f}; onerror {quit -code 1 -f}; run -all; quit -f'])
    (SIM/(top+'.log')).write_text(out,encoding='utf-8')
    passed=code==0 and 'TB_RESULT: PASS' in out and 'Fatal:' not in out
    print(top, 'PASS' if passed else 'FAIL')
    print('\n'.join(l for l in out.splitlines() if 'TB_RESULT' in l or 'Fatal' in l or 'Error' in l))
    ok &= passed
sys.exit(0 if ok else 1)
