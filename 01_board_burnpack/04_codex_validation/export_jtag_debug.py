"""Export routed ChipWatcher metadata matching a published candidate bit."""
from pathlib import Path
import hashlib,re,subprocess,xml.etree.ElementTree as ET

def export(dest,output,td):
    dest=Path(dest);output=Path(output);td=Path(td)
    phy=dest/'td_project/camera_to_dsi_display_Runs/phy_1'
    assert (phy/'cw/debug_hub/top_debug_hub_ooc.db').exists(),'Missing implemented JTAG hub'
    tcl=phy/'export_jtag.tcl'
    tcl.write_text('source settings.cfg\nimport_device ph1_35p.db -package PH1P35MDG324 -speed 3\nopen_project camera_to_dsi_display.prj -noanalyze\nimport_db camera_to_dsi_display_pr.db\nsetup_debugger {'+output.parent.as_posix()+'} -bit {'+Path(str(output)+'.bit').as_posix()+'}\nexport_chipwatcher '+output.name+'.cwc -dir {'+output.parent.as_posix()+'} -add_bid\nexit\n',encoding='utf-8')
    p=subprocess.run([str(td/'bin/td_commands_prompt.exe'),tcl.as_posix()],cwd=phy,capture_output=True,text=True,errors='replace')
    (phy/'jtag_metadata_export.log').write_text(p.stdout+p.stderr,encoding='utf-8')
    if p.returncode or re.search(r'\bERROR:',p.stdout+p.stderr):raise RuntimeError('JTAG metadata export failed; see jtag_metadata_export.log')
    cwc=Path(str(output)+'.cwc')
    if not cwc.exists() or cwc.stat().st_size<=1000:raise RuntimeError('Missing or empty ChipWatcher configuration')
    ET.parse(cwc);text=cwc.read_text(encoding='utf-8')
    for group in ['camera','awb','mipi','ddr','read','write']:
        if 'u_sc520_watch_'+group not in text:raise RuntimeError('Missing watcher group '+group)
    for signal in ['dbg_ae','dbg_ag','dbg_awb_r_gain','dbg_underflow_count']:
        if signal not in text:raise RuntimeError('Missing observation '+signal)
    return hashlib.sha256(cwc.read_bytes()).hexdigest()
