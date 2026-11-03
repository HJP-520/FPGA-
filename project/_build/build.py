import os
from pathlib import Path
import sys,subprocess,json,hashlib,re,time,shutil
from clock_check import check_clocks
B=Path(__file__).resolve().parent
T=B.parent
O=T/'outputs';O.mkdir(exist_ok=True)
TD=Path(os.environ.get('SC520_TD_ROOT','D:/TD6.2.1'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def sources():return {p.relative_to(T).as_posix():sha(p) for p in (T/'user_source').rglob('*') if p.is_file()}
stage=sys.argv[1];seed=int(sys.argv[2])if len(sys.argv)>2 else 9
guard=float(sys.argv[3])if len(sys.argv)>3 else (0.0 if stage=='syn' else 0.350)
d=T/'td_project/camera_to_dsi_display_Runs'/('syn_1'if stage=='syn'else f'servo_seed{seed}')
d.mkdir(parents=True,exist_ok=True)
for name in ('settings.cfg','camera_to_dsi_display.prj'):
 shutil.copy2(B/'templates'/('syn' if stage=='syn' else 'phy')/name,d/name)
for asset in ('logo_mem.hex','ui_title.hex','ui_font.dath','ui_font_compact.dath','sc13_r_pixel.dath','sc13_b_pixel.dath','sc13_rows.dath','sc13_x.dath'):
 shutil.copy2(T/'user_source/hdl_source'/('ui/logo_mem.hex' if asset=='logo_mem.hex' else 'isp/'+asset if asset.startswith('sc13') else asset),d/asset)
if stage!='syn':
 for f in (T/'td_project/camera_to_dsi_display_Runs/syn_1').glob('*.dath'):shutil.copy2(f,d/f.name)
 shutil.copy2(T/'td_project/camera_to_dsi_display_Runs/syn_1/logo_mem.hex',d/'logo_mem.hex')
src=sources()
if stage=='syn':
 s=(TD/'doc/scripts/DefaultFlow.tcl').read_text().replace('if { ![info exists chipDebugger] } {','if { 1 } {').replace('if { [info exists sp] } {','if { $step != 0 } {')
 s=s.replace('export_db ${prj_name}_gate.db','export_db ${prj_name}_gate.db\n  write_verilog ui_gate_netlist.v')
else:
 # RTL regression may run concurrently with implementation. Release requires its final matching receipt.
 v=json.loads((O/'verification.json').read_text());rtl_ready=v['pass'] and v['source_hashes']==src
 syn=json.loads((O/'syn.json').read_text());assert syn['pass']and syn['source_hashes']==src
 constraint=T/'td_project/camera_to_dsi_display.sdc'
 if guard:
  constraint=d/'implementation.sdc';constraint.write_text((T/'td_project/camera_to_dsi_display.sdc').read_text()+'\nset_clock_uncertainty -setup '+str(guard)+' [get_clocks {MIPI_RX_BYTE_CLK}]\nset_clock_uncertainty -setup '+str(guard)+' [get_clocks {HDMI_PIXEL_CLK}]\n')
  (d/'signoff_restore.sdc').write_text('set_clock_uncertainty -setup 0.000 [get_clocks {MIPI_RX_BYTE_CLK}]\n')
 restore = '\n'.join(['set_clock_uncertainty -setup 0.000 [get_clocks {MIPI_RX_BYTE_CLK}]','set_clock_uncertainty -setup 0.000 [get_clocks {HDMI_PIXEL_CLK}]']) if guard else ''
 s=f'''source settings.cfg
import_device ph1_35p.db -package PH1P35MDG324 -speed 3
open_project camera_to_dsi_display.prj -noanalyze
import_db {{{(T/'td_project/camera_to_dsi_display_Runs/syn_1/camera_to_dsi_display_gate.db').as_posix()}}}
set_param place seed {seed}
clear_user_sdc
read_sdc {{{constraint.as_posix()}}}
place
route
update_timing -mode final
fix_hold
{'report_qor -step route -file guardband.qor' if guard else ''}
{'report_timing_summary -file guardband_timing.rpt' if guard else ''}
{restore}
update_timing -mode final
report_qor -step route -file route.qor
report_area -io_info -file ui_phy.area
report_timing_summary -file final_timing.rpt
export_db ui_pr.db
write_verilog ui_physical_netlist.v
puts {{UI_ROUTE_COMPLETE}}
exit
'''
flow=d/'ui_flow.tcl';flow.write_text(s)
start=time.time()
with(d/'build.log').open('w',encoding='utf-8')as f:p=subprocess.run([str(TD/'bin/td_commands_prompt.exe'),flow.name],cwd=d,stdout=f,stderr=subprocess.STDOUT)
log=(d/'build.log').read_text(errors='replace');ok=p.returncode==0 and not re.search(r'ERROR:|couldn.t read file|invalid command|Error:',log)
if stage=='syn':ok=ok and (d/'camera_to_dsi_display_gate.db').exists() and (d/'ui_gate_netlist.v').exists()
rec={'pass':ok,'stage':stage,'seed':seed,'implementation_setup_guard_ns':guard,'implementation_hdmi_setup_guard_ns':guard,'signoff_sdc_sha256':sha(T/'td_project/camera_to_dsi_display.sdc'),'seconds':round(time.time()-start,1),'source_hashes':src,'log':str(d/'build.log'),'programmed':False}
if stage!='syn':
 q=(d/'route.qor').read_text()if(d/'route.qor').exists()else''
 for key in ('Setup WNS','Hold WNS','#slices','#RAMs','#DSPs'):
  m=re.search(r'\|\s*'+re.escape(key)+r'\s*\|\s*(-?\d+)',q);rec[key]=int(m[1])if m else None
 rec['clock_integrity_pass']=check_clocks((d/'final_timing.rpt').read_text()) if (d/'final_timing.rpt').exists() else False
 rec['implementation_guard_pass']=(('sdc uncertainty: '+format(guard,'.3f')+'ns') in (d/'guardband_timing.rpt').read_text()) if guard and (d/'guardband_timing.rpt').exists() else not guard
 rec['pass']=ok and rec['clock_integrity_pass'] and rec['implementation_guard_pass'] and 'UI_ROUTE_COMPLETE'in log and rec['Setup WNS'] is not None and rec['Setup WNS']>=50 and rec['Hold WNS']>=0
dest=O/('syn'if stage=='syn'else f'seed{seed}');dest.mkdir(exist_ok=True)
for name in ('build.log','route.qor','ui_phy.area','final_timing.rpt','guardband.qor','guardband_timing.rpt','implementation.sdc','signoff_restore.sdc'):
 if(d/name).exists():shutil.copy2(d/name,dest/name)
(dest/'result.json').write_text(json.dumps(rec,indent=2));(O/('syn.json'if stage=='syn'else f'phy_seed{seed}.json')).write_text(json.dumps(rec,indent=2))
print(json.dumps({k:v for k,v in rec.items()if k!='source_hashes'},indent=2),flush=True)
if not rec['pass']:sys.exit(1)
