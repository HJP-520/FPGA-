"""Run current-design test benches without historical RTL implementations."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess
T=Path(__file__).resolve().parents[1];H=T/'user_source/hdl_source';O=T/'outputs'
jobs=json.loads((T/'_build/simulation_jobs.json').read_text())
ap=argparse.ArgumentParser();ap.add_argument('--list',action='store_true');ap.add_argument('--test',action='append',default=[]);args=ap.parse_args()
if args.list:print('\n'.join(j['name'] for j in jobs));raise SystemExit(0)
assert not args.test or set(args.test)<={j['name'] for j in jobs},'Unknown test name'
selected=[j for j in jobs if not args.test or j['name'] in args.test]
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
sources={p.relative_to(T).as_posix():sha(p) for p in (T/'user_source').rglob('*') if p.is_file()}
def tool(name):
    root=os.environ.get('IVERILOG_BIN');p=Path(root)/(name+('.exe' if os.name=='nt' else '')) if root else None
    if p and p.is_file():return str(p)
    p=shutil.which(name)
    if not p:raise SystemExit(f'{name} not found. Set IVERILOG_BIN.')
    return p
iverilog,vvp=tool('iverilog'),tool('vvp');O.mkdir(exist_ok=True)
top=(H/'design_top_wrapper.v').read_text(encoding='utf-8')
hx=int(re.search(r'parameter SERVO_HOME_X\s*=\s*(\d+)',top)[1]);hy=int(re.search(r'parameter SERVO_HOME_Y\s*=\s*(\d+)',top)[1])
profile,maxstep=map(int,re.search(r'\.STABILITY_EN\((\d+)\),\.MAX_STEP\((\d+)\)',top).groups())
params=f'`define PROD_HOME_X {hx}\n`define PROD_HOME_Y {hy}\n`define PROD_PROFILE {profile}\n`define PROD_MAX_STEP {maxstep}\n`define PROD_SMOOTH 1\n'
assets=[H/'ui/logo_mem.hex',H/'ui_title.hex',H/'ui_font.dath',H/'ui_font_compact.dath',T/'assets/logo_rgb888.hex',T/'assets/title_golden.hex'];results={}
for job in selected:
    name=job['name'];d=O/'simulation'/name;d.mkdir(parents=True,exist_ok=True);extra=[]
    if name in ('BINARY_DETAIL','BINARY_DETAIL720P'):extra=list((T/'sim/local_fixture').glob('*.hex'))
    if name=='EDGE_DETAIL720P':extra=list((T/'sim/edge_detail_fixture').glob('*.hex'))
    if name in ('BINARY_DETAIL','BINARY_DETAIL720P','EDGE_DETAIL720P') and not extra:raise SystemExit('Run scripts/prepare_sim.py from the repository root first.')
    for asset in assets+extra+list((H/'isp').glob('sc13*.dath')):shutil.copy2(asset,d/asset.name)
    (d/'production_servo_params.vh').write_text(params,encoding='utf-8')
    files=[T/f for f in job['files']]
    commands=[('compile',[iverilog,'-g2012',*job['flags'],'-s',job['top'],'-o',str(d/'simulation.vvp'),*map(str,files)]),('simulation',[vvp,str(d/'simulation.vvp')])]
    for label,command in commands:
        with (d/f'{label}.log').open('w',encoding='utf-8') as log:p=subprocess.run(command,cwd=d,stdout=log,stderr=subprocess.STDOUT,timeout=600)
        text=(d/f'{label}.log').read_text(errors='replace');assert p.returncode==0 and not re.search(r'ERROR:|FATAL:|Unable to open|Error loading design',text),text[-3000:]
    assert f'TB_RESULT: {name} PASS' in text,text[-3000:]
    results[name]={'pass':True,'source_hashes':{f.relative_to(T).as_posix():sha(f) for f in files+extra},'summary':[s for s in text.splitlines() if 'TB_RESULT:' in s]};print(name,'PASS',flush=True)
receipt={'pass':True,'full_suite':len(selected)==len(jobs),'source_hashes':sources,'tests':results,'suite_sha256':sha(T/'_build/simulation_jobs.json'),'signoff_sdc_sha256':sha(T/'td_project/camera_to_dsi_display.sdc'),'scope':'Fresh current-design RTL tasks, synchronous behavior memory models; not board acceptance.'}
target=O/('verification.json' if receipt['full_suite'] else 'verification_subset.json');target.write_text(json.dumps(receipt,indent=2),encoding='utf-8');print(f'{len(results)} tasks passed; receipt: {target}')
