"""Rebuild in an isolated tree; publish only fresh, timing-clean SRAM candidates."""
from pathlib import Path
import argparse,shutil,subprocess,time,json,hashlib,re

def build(root,profile,td):
    source=root/'02_TD_project_rebuild/lab_ex1'
    dest=root/'04_codex_validation/work_build'/profile/'lab_ex1'
    dest.mkdir(parents=True,exist_ok=True)
    shutil.copytree(source/'user_source',dest/'user_source',dirs_exist_ok=True)
    for name in ['camera_to_dsi_display.al','camera_to_dsi_display.sdc']:
        p=dest/'td_project'/name;p.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source/'td_project'/name,p)
    if (source/'td_project/al_ip').exists():
        shutil.copytree(source/'td_project/al_ip',dest/'td_project/al_ip',dirs_exist_ok=True)
    values={'main':(24,1),'sat_bypass':(16,1),'unity':(16,0)}
    k,awb=values[profile]
    p=dest/'user_source/hdl_source/design_top_wrapper.v'
    s=p.read_text(encoding='utf-8',errors='surrogateescape')
    s=re.sub(r"SAT_K_Q4 = 6'd\d+",f"SAT_K_Q4 = 6'd{k}",s,count=1)
    s=re.sub(r'AWB_ENABLE = [01]',f'AWB_ENABLE = {awb}',s,count=1)
    p.write_text(s,encoding='utf-8',errors='surrogateescape')
    provenance={'profile':profile,'sat_k_q4':k,'awb_enable':awb,'board_verified':False,
        'source_sha256':{str(p.relative_to(dest)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (dest/'user_source').rglob('*') if p.is_file()},'stages':{}}
    for stage in ['syn_1','phy_1']:
        original=source/'td_project/camera_to_dsi_display_Runs'/stage
        cwd=dest/'td_project/camera_to_dsi_display_Runs'/stage;cwd.mkdir(parents=True,exist_ok=True)
        for name in ['settings.cfg','camera_to_dsi_display.prj']:shutil.copy2(original/name,cwd/name)
        started=time.time();log=cwd/'codex_build.log'
        with log.open('w',encoding='utf-8') as f:
            p=subprocess.run([str(td/'bin/td_commands_prompt.exe'),(td/'doc/scripts/DefaultFlow.tcl').as_posix()],cwd=cwd,stdout=f,stderr=subprocess.STDOUT)
        artifact=cwd/('camera_to_dsi_display_gate.db' if stage=='syn_1' else 'camera_to_dsi_display.bit')
        if p.returncode or not artifact.exists() or artifact.stat().st_mtime<started:
            raise RuntimeError(f'{stage} failed or did not produce a fresh artifact; see {log}')
        provenance['stages'][stage]={'seconds':round(time.time()-started,1),'exit_code':p.returncode}
        print(stage,'complete',flush=True)
    route=cwd/'route.qor';report=route.read_text(encoding='utf-8')
    for name in ['Setup WNS','Hold WNS']:
        value=int(re.search(r'\|\s*'+name+r'\s*\|\s*(-?\d+)',report).group(1))
        provenance[name+'_ps']=value
        if value<0:raise RuntimeError('Timing failed; candidate not published')
    output=root/'01_bitstream_flash_direct'/f'camera_to_dsi_display_codex_{profile}'
    for suffix,original in [('.bit','camera_to_dsi_display.bit'),('_inst.bid','camera_to_dsi_display_inst.bid')]:
        shutil.copy2(cwd/original,Path(str(output)+suffix))
    provenance['bit_sha256']=hashlib.sha256(Path(str(output)+'.bit').read_bytes()).hexdigest()
    Path(str(output)+'_manifest.json').write_text(json.dumps(provenance,indent=2),encoding='utf-8')
    print('Candidate:',str(output)+'.bit')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--profile',choices=['main','sat_bypass','unity'],default='main')
    p.add_argument('--td',type=Path,default=Path('D:/TD6.2.1'))
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    a=p.parse_args();build(a.root,a.profile,a.td)
