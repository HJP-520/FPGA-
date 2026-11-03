"""Export one current firmware after matching RTL, implementation and sources."""
from pathlib import Path
import hashlib,json,os,re,shutil,subprocess,sys
from clock_check import check_clocks
T=Path(__file__).resolve().parents[1];O=T/'outputs';seed=int(sys.argv[1]) if len(sys.argv)>1 else 9;sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
hs={p.relative_to(T).as_posix():sha(p) for p in (T/'user_source').rglob('*') if p.is_file()}
v=json.loads((O/'verification.json').read_text());s=json.loads((O/'syn.json').read_text());q=json.loads((O/f'phy_seed{seed}.json').read_text())
for r in (v,s,q):assert r['pass'] and r['source_hashes']==hs,'Receipt is stale'
suite=json.loads((T/'_build/simulation_jobs.json').read_text());assert v['full_suite'] and set(v['tests'])=={j['name'] for j in suite};assert v['suite_sha256']==sha(T/'_build/simulation_jobs.json')
for test in v['tests'].values():assert test['pass'] and all(sha(T/n)==digest for n,digest in test['source_hashes'].items())
assert q['#slices']<=21216 and q['#RAMs']<=108 and q['#DSPs']<=40
assert q['Setup WNS']>=50 and q['Hold WNS']>=0 and q['clock_integrity_pass'] and q['implementation_guard_pass'];assert q['signoff_sdc_sha256']==v['signoff_sdc_sha256']==sha(T/'td_project/camera_to_dsi_display.sdc')
D=T/f'td_project/camera_to_dsi_display_Runs/servo_seed{seed}';name='SC520_view_manual_v17'
tcl=f'''source settings.cfg
import_device ph1_35p.db -package PH1P35MDG324 -speed 3
open_project camera_to_dsi_display.prj -noanalyze
import_db {{{(D/'ui_pr.db').as_posix()}}}
set_clock_uncertainty -setup 0.000 [get_clocks {{MIPI_RX_BYTE_CLK}}]
set_clock_uncertainty -setup 0.000 [get_clocks {{HDMI_PIXEL_CLK}}]
update_timing -mode final
report_qor -step route -file export.qor
report_timing_summary -file export_timing.rpt
export_bid {name}_inst.bid
bitgen -bit {name}.bit
puts {{EXPORT_PASS}}
exit
'''
(D/'export.tcl').write_text(tcl);TD=Path(os.environ.get('SC520_TD_ROOT','D:/TD6.2.1'))
with (D/'export.log').open('w') as log:p=subprocess.run([str(TD/'bin/td_commands_prompt.exe'),'export.tcl'],cwd=D,stdout=log,stderr=subprocess.STDOUT,timeout=300)
log=(D/'export.log').read_text(errors='replace');assert p.returncode==0 and 'EXPORT_PASS' in log and not re.search(r'ERROR:|couldn.t read file|invalid command',log);assert check_clocks((D/'export_timing.rpt').read_text())
report=(D/'export.qor').read_text()
for k in ('Setup WNS','Hold WNS','#slices','#RAMs','#DSPs'):assert int(re.search(r'\|\s*'+re.escape(k)+r'\s*\|\s*(-?\d+)',report)[1])==q[k]
R=O/'release';R.mkdir(exist_ok=True);bit=R/f'{name}.bit';shutil.copy2(D/bit.name,bit)
manifest={'profile':'view_manual_v17_rebuild','bit':bit.name,'bit_sha256':sha(bit),'bit_bytes':bit.stat().st_size,'source_hashes':hs,'tests':v['tests'],'setup_wns_ps':q['Setup WNS'],'hold_wns_ps':q['Hold WNS'],'slices':q['#slices'],'eram':q['#RAMs'],'dsp':q['#DSPs'],'programmed':False,'board_verified':False}
(R/'manifest.json').write_text(json.dumps(manifest,indent=2));(R/f'{bit.name}.sha256.txt').write_text(sha(bit)+' *'+bit.name+'\n');print('RELEASE_READY',bit,sha(bit))
