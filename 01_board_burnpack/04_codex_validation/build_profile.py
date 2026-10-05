"""Rebuild in an isolated tree; publish only fresh, timing-clean SRAM candidates."""
from pathlib import Path
import argparse,shutil,subprocess,time,json,hashlib,re

def build(root,profile,td,startup_ag=None):
    source=root/'02_TD_project_rebuild/lab_ex1'
    dest=root/'04_codex_validation/work_build'/profile/'lab_ex1'
    dest.mkdir(parents=True,exist_ok=True)
    shutil.copytree(source/'user_source',dest/'user_source',dirs_exist_ok=True)
    for name in ['camera_to_dsi_display.al','camera_to_dsi_display.sdc']:
        p=dest/'td_project'/name;p.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source/'td_project'/name,p)
    if (source/'td_project/al_ip').exists():
        shutil.copytree(source/'td_project/al_ip',dest/'td_project/al_ip',dirs_exist_ok=True)
    values={'jtag':(24,1,80),'debug':(24,1,80),'balanced':(24,1,80),'main':(24,1,80),'sat_bypass':(16,1,80),'unity':(16,0,16)}
    k,awb,ag=values[profile]
    if startup_ag is not None:ag=startup_ag
    if not 16 <= ag <= 176:raise ValueError('startup AG must be 16..176')
    p=dest/'user_source/hdl_source/design_top_wrapper.v'
    s=p.read_text(encoding='utf-8',errors='surrogateescape')
    s=re.sub(r"SAT_K_Q4 = 6'd\d+",f"SAT_K_Q4 = 6'd{k}",s,count=1)
    s=re.sub(r'AWB_ENABLE = [01]',f'AWB_ENABLE = {awb}',s,count=1)
    s=re.sub(r"STARTUP_AG = 16'd\d+",f"STARTUP_AG = 16'd{ag}",s,count=1)
    ae=int(re.search(r"STARTUP_AE = 16'd(\d+)",s).group(1))
    p.write_text(s,encoding='utf-8',errors='surrogateescape')
    provenance={'profile':profile,'sat_k_q4':k,'awb_enable':awb,'startup_ag':ag,'startup_ae':ae,'board_verified':False,
        'source_sha256':{str(p.relative_to(dest)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (dest/'user_source').rglob('*') if p.is_file()},'stages':{}}
    for stage in ['syn_1','phy_1']:
        original=source/'td_project/camera_to_dsi_display_Runs'/stage
        cwd=dest/'td_project/camera_to_dsi_display_Runs'/stage;cwd.mkdir(parents=True,exist_ok=True)
        for name in ['settings.cfg','camera_to_dsi_display.prj']:shutil.copy2(original/name,cwd/name)
        if profile in ['debug','jtag'] and stage=='syn_1':
            from prepare_jtag_debug import prepare
            prepare(dest)
            provenance['source_sha256']={str(p.relative_to(dest)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (dest/'user_source').rglob('*') if p.is_file()}
            provenance['jtag_ip_sha256']=hashlib.sha256((dest/'td_project/al_ip/sc520_jtag_status/sc520_jtag_status.sv').read_bytes()).hexdigest()
        started=time.time();log=cwd/'codex_build.log'
        flow=td/'doc/scripts/DefaultFlow.tcl'
        if profile in ['debug','jtag']:
            # The packaged settings point to an absent chip_debugger folder.
            # At the physical stage infer cores from the flattened netlist.
            local_flow=dest/'td_project/jtag_flow.tcl'
            flow_text=flow.read_text(encoding='utf-8')
            init='if { ![info exists alRun] } { source ./settings.cfg }'
            assert init in flow_text
            # import_db restores the old flow parameters, so clearing the
            # variable before import is insufficient. Force the no-argument
            # form in the physical functions themselves.
            flow_text=flow_text.replace('if { ![info exists chipDebugger] } {','if { 1 } {')
            local_flow.write_text(flow_text,encoding='utf-8')
            flow=local_flow
        with log.open('w',encoding='utf-8') as f:
            p=subprocess.run([str(td/'bin/td_commands_prompt.exe'),flow.as_posix()],cwd=cwd,stdout=f,stderr=subprocess.STDOUT)
        artifact=cwd/('camera_to_dsi_display_gate.db' if stage=='syn_1' else 'camera_to_dsi_display.bit')
        errors=re.search(r'\bERROR:',log.read_text(encoding='utf-8',errors='replace'))
        if p.returncode or errors or not artifact.exists() or artifact.stat().st_mtime<started:
            raise RuntimeError(f'{stage} failed or did not produce a fresh artifact; see {log}')
        provenance['stages'][stage]={'seconds':round(time.time()-started,1),'exit_code':p.returncode}
        print(stage,'complete',flush=True)
    route=cwd/'route.qor';report=route.read_text(encoding='utf-8')
    for name in ['Setup WNS','Hold WNS']:
        value=int(re.search(r'\|\s*'+name+r'\s*\|\s*(-?\d+)',report).group(1))
        provenance[name+'_ps']=value
        if value<0:raise RuntimeError('Timing failed; candidate not published')
    if profile in ['debug','jtag']:
        watchers=list((dest/'td_project/camera_to_dsi_display_Runs').glob('*/cw/*/*watcherInst.sv'))
        if len(watchers)!=6:raise RuntimeError(f'Expected 6 implemented ChipWatcher cores, found {len(watchers)}; candidate not published')
        provenance['implemented_watcher_cores']=len(watchers)
    output=root/'01_bitstream_flash_direct'/f'camera_to_dsi_display_codex_{profile}'
    for suffix,original in [('.bit','camera_to_dsi_display.bit'),('_inst.bid','camera_to_dsi_display_inst.bid')]:
        shutil.copy2(cwd/original,Path(str(output)+suffix))
    if profile in ['debug','jtag']:
        from export_jtag_debug import export
        provenance['cwc_sha256']=export(dest,output,td)
        provenance['jtag_hub_generated']=True
        provenance['jtag_ip_source_sha256']={str(p.relative_to(dest)):hashlib.sha256(p.read_bytes()).hexdigest() for folder in (dest/'td_project/al_ip').glob('sc520_watch_*') for p in folder.rglob('*') if p.is_file()}
    provenance['bit_sha256']=hashlib.sha256(Path(str(output)+'.bit').read_bytes()).hexdigest()
    Path(str(output)+'_manifest.json').write_text(json.dumps(provenance,indent=2),encoding='utf-8')
    print('Candidate:',str(output)+'.bit')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--profile',choices=['jtag','debug','balanced','main','sat_bypass','unity'],default='balanced')
    p.add_argument('--td',type=Path,default=Path('D:/TD6.2.1'))
    p.add_argument('--root',type=Path,default=Path(__file__).resolve().parent.parent)
    p.add_argument('--startup-ag',type=int,help='Manual gain index 16..176; 80 is the 4x table entry')
    a=p.parse_args();build(a.root,a.profile,a.td,a.startup_ag)
