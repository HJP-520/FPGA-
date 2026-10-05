"""Decode ChipWatcher CSV snapshots; explicitly select the exported radix.

This reads exported waveform files, not the JTAG cable. Capture/export each
clock-domain tab using TD's ChipWatcher, then pass those CSV files here.
"""
from pathlib import Path
import argparse,csv,io,json,re,datetime

PROBES={
    'camera':['dbg_ae','dbg_ag','dbg_sensor_id','dbg_cam_flags'],
    'mipi':['dbg_frames','dbg_lines','dbg_mipi_flags'],
    'ddr':['dbg_ddr_flags'],
    'awb':['dbg_awb_r_gain','dbg_awb_b_gain','dbg_awb_stat_beats','dbg_awb_total_beats'],
    'write':['dbg_overflow_count','dbg_frame_overflow','dbg_previous_overflow'],
    'read':['dbg_underflow_count','dbg_read_corrupt']}

def field_name(header):
    for names in PROBES.values():
        for name in names:
            if re.search(r'(?<![a-zA-Z0-9_])'+name+r'(?![a-zA-Z0-9_])',header):return name
    probe=re.search(r'probe(\d+)',header,re.I)
    if probe:
        for group,names in PROBES.items():
            if ('sc520_watch_'+group in header or 'ChipWatcher_sc520_'+group in header):
                index=int(probe.group(1))
                if index<len(names):return names[index]
    return None

def value(raw,radix):
    s=raw.strip().replace('_','')
    if not s:return None
    if s.lower().startswith(('0x','0b','0o')):return int(s,0)
    if re.search('[xz?]',s,re.I):return None
    verilog=re.fullmatch(r"\d+'([hdb])([0-9a-f]+)",s,re.I)
    if verilog:return int(verilog.group(2),{'h':16,'d':10,'b':2}[verilog.group(1).lower()])
    return int(s,{'hex':16,'decimal':10,'binary':2}[radix])

def decode(paths,radix):
    fields={};sources=[]
    for p in paths:
        data=p.read_bytes()
        text=None
        for encoding in (['utf-16'] if data[:2] in [b'\xff\xfe',b'\xfe\xff'] else ['utf-8-sig','gb18030']):
            try:text=data.decode(encoding);break
            except UnicodeDecodeError:pass
        if text is None:raise ValueError(f'Cannot decode {p}')
        try:dialect=csv.Sniffer().sniff(text[:8192],delimiters=',;\t')
        except csv.Error:dialect=csv.excel
        rows=list(csv.reader(io.StringIO(text),dialect));header=None;mapping={}
        for row in rows:
            candidate={i:field_name(cell) for i,cell in enumerate(row)}
            candidate={i:n for i,n in candidate.items() if n}
            if candidate:header=row;mapping=candidate;continue
            if header is None:continue
            for i,name in mapping.items():
                if i>=len(row):continue
                try:n=value(row[i],radix)
                except ValueError:continue
                if n is not None:fields[name]=n
        sources.append({'file':str(p.resolve()),'mtime':datetime.datetime.fromtimestamp(p.stat().st_mtime).isoformat()})
    if not fields:raise ValueError('No recognized probe headers; export names or hierarchy/probe columns and select the matching radix')
    result={'export_radix':radix,'raw_fields':fields,'csv_sources':sources,
            'note':'Separate clock-domain captures are not an atomic board-wide snapshot. AE/AG are FPGA control values, not sensor register readback.'}
    if 'dbg_ag' in fields:
        ag=fields['dbg_ag'];step=max(0,min(160,ag-16))
        result['gain_table_x']=32.0 if step==160 else (2**(step//32))*(1+(step%32)/32)
    for field,label in [('dbg_awb_r_gain','awb_r_gain_x'),('dbg_awb_b_gain','awb_b_gain_x')]:
        if field in fields:result[label]=fields[field]/65536
    for field,names in [('dbg_cam_flags',['i2c_error','sensor_id_ok','ae_request','ae_done','sensor_config_done']),
                        ('dbg_mipi_flags',['lane_error','length_error','line_count_error','frame_done']),
                        ('dbg_ddr_flags',['write_busy','user_ready','calibrated'])]:
        if field in fields:result[field+'_decoded']={name:bool(fields[field] & (1<<bit)) for bit,name in enumerate(names)}
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('csv_files',nargs='+',type=Path)
    p.add_argument('--radix',choices=['decimal','hex','binary'],required=True,help='Must match the waveform export display radix')
    p.add_argument('--output',type=Path)
    a=p.parse_args();result=decode(a.csv_files,a.radix);s=json.dumps(result,ensure_ascii=False,indent=2)
    if a.output:a.output.write_text(s+'\n',encoding='utf-8')
    print(s)
