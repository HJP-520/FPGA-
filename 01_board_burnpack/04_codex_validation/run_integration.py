from pathlib import Path
import subprocess,sys,os
MSIM=Path(os.environ.get('MODELSIM_BIN','D:/ModelSim/win64'))
H=Path(__file__).resolve().parent;B=Path(os.environ.get('SC520_RTL_ROOT',str(H.parent/'02_TD_project_rebuild/lab_ex1/user_source/hdl_source')));D=B/'isp/demosaic_4x_2_0';S=H/'tests'
files=[B/'isp/isp_top.v',B/'awb.v',B/'signal_delay.v',B/'isp/data128_96/data128_96.v',B/'isp/data96_128/data96_128.v']
files+=list(D.glob('*.v'))
for p in ['blk_mem_gen_demosaic','blk_mem_gen_zhenghe']: files+=list((D/p).rglob('*.v'))
files+=list((B.parent/'ip_source/blk_mem_gen_awb_delay_signal').glob('*.v'))
files+=[H/'support/divider_gate_sim.v',H/'support/ph1p_logic_eram_stub.v',H/'tb_isp_integration.sv']
p=subprocess.run([str(MSIM/'vlog.exe'),'-sv',*[str(f) for f in files]],cwd=S,capture_output=True,text=True,errors='replace')
(S/'tb_isp_integration_compile.log').write_text(p.stdout+p.stderr,encoding='utf-8')
if p.returncode: print(p.stdout+p.stderr);sys.exit(1)
with (S/'tb_isp_integration.log').open('w',encoding='utf-8') as log:
    p=subprocess.run([str(MSIM/'vsim.exe'),'-c','-onfinish','exit','tb_isp_integration','-do','onbreak {quit -code 1 -f}; onerror {quit -code 1 -f}; run -all; quit -f'],cwd=S,stdout=log,stderr=subprocess.STDOUT)
out=(S/'tb_isp_integration.log').read_text(encoding='utf-8',errors='replace')
print('\n'.join(l for l in out.splitlines() if 'TB_RESULT' in l or 'Fatal' in l or 'Error' in l))
sys.exit(0 if p.returncode==0 and 'TB_RESULT: PASS' in out else 1)
