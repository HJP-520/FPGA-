"""Add observational ChipWatcher probes only to an isolated debug build tree.

Uses the same ChipWatcher black-box interface as the vendor IP shipped in
this project (SWUG111 2.2.1). No probe feeds back into the video datapath.
"""
from pathlib import Path

ATTR='(* MARK_DEBUG = "TRUE" *) '

def prepare(dest):
    base=Path(dest)/'user_source/hdl_source'
    p=base/'design_top_wrapper.v'
    text=p.read_text(encoding='utf-8',errors='surrogateescape')
    block='''
    // Read-only JTAG observations; local-clock copies avoid multi-bit CDC.
    (* MARK_DEBUG = "TRUE" *) reg [15:0] dbg_ae, dbg_ag, dbg_sensor_id;
    (* MARK_DEBUG = "TRUE" *) reg [4:0] dbg_cam_flags;
    always @(posedge S_24m_clk or negedge S_rst_n) begin
        if (!S_rst_n) begin
            dbg_ae <= 0; dbg_ag <= 0; dbg_sensor_id <= 0; dbg_cam_flags <= 0;
        end else begin
            dbg_ae <= S_ae; dbg_ag <= S_ag; dbg_sensor_id <= S_cam_sensor_id;
            dbg_cam_flags <= {S_cam_cfg_done, S_ae_cfg_done, S_ae_req,
                              S_cam_sensor_id_ok, S_cam_i2c_error};
        end
    end
    (* MARK_DEBUG = "TRUE" *) reg [31:0] dbg_frames;
    (* MARK_DEBUG = "TRUE" *) reg [10:0] dbg_lines;
    (* MARK_DEBUG = "TRUE" *) reg [3:0] dbg_mipi_flags;
    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if (!S_rst_n) begin dbg_frames <= 0; dbg_lines <= 0; dbg_mipi_flags <= 0; end
        else begin
            if (S_csi_frame_end) dbg_frames <= dbg_frames + 1'b1;
            dbg_lines <= S_mipi_line_count;
            dbg_mipi_flags <= {S_mipi_frame_done, S_mipi_last_line_error,
                               S_mipi_last_length_error, S_mipi_last_lane_error};
        end
    end
    (* MARK_DEBUG = "TRUE" *) reg [2:0] dbg_ddr_flags;
    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if (!S_rst_n) dbg_ddr_flags <= 0;
        else dbg_ddr_flags <= {S_init_calib_complete, S_ddr_user_ready, S_video_in_wr_busy};
    end

'''
    anchor="    assign O_screen_pwm = 1'b1;"
    assert text.count(anchor)==1 and 'reg [31:0] dbg_frames' not in text
    p.write_text(text.replace(anchor,block+anchor,1),encoding='utf-8',errors='surrogateescape')
    # Mark local state in its actual clock domain instead of reading it through
    # a hierarchy reference or asynchronous bus in the top module.
    edits={
        'awb.v':['reg [31:0] stat_beats, frame_beats_total;',
                 'reg  [19:0]   in_r_r1;', 'reg  [19:0]   in_b_r1;'],
        'isp/awb/awb.v':['reg [31:0] stat_beats, frame_beats_total;',
                        'reg  [19:0]   in_r_r1;', 'reg  [19:0]   in_b_r1;'],
        'video_in.v':['reg S_frame_overflow, S_previous_overflow;',
                      '(* keep = "true" *) reg [15:0] S_overflow_count;'],
        'video_out.v':['reg S_read_corrupt, S_pixel_vsync_d;',
                       '(* keep = "true" *) reg [15:0] S_underflow_count;']}
    for name,lines in edits.items():
        p=base/name;text=p.read_text(encoding='utf-8',errors='surrogateescape')
        for line in lines:
            assert text.count(line)==1,(name,line)
            replacement=(line.replace('(* keep = "true" *)','(* keep = "true", MARK_DEBUG = "TRUE" *)')
                         if line.startswith('(*') else ATTR+line)
            text=text.replace(line,replacement,1)
        p.write_text(text,encoding='utf-8',errors='surrogateescape')
    # Make the isolated project usable in the TD GUI as well as command line.
    p=Path(dest)/'td_project/camera_to_dsi_display.al'
    import re
    text=p.read_text(encoding='utf-8')
    text=re.sub(r'(<Project[^>]*\bPath=")[^"]*',lambda m:m.group(1)+(Path(dest)/'td_project').as_posix(),text,count=1)
    p.write_text(text,encoding='utf-8')
    # Explicit IP instances: this command-line flow retains MARK_DEBUG nets
    # but does not create watcher cores automatically without GUI settings.
    # Do not rely on a positive bitstream build as evidence of a working hub.
    instances={
        'design_top_wrapper.v':'''\n    wire [19:0] dbg_awb_r_gain, dbg_awb_b_gain;
    wire [31:0] dbg_awb_stat_beats, dbg_awb_total_beats;
    wire [15:0] dbg_overflow_count, dbg_underflow_count;
    wire dbg_frame_overflow, dbg_previous_overflow, dbg_read_corrupt;
    ChipWatcher_sc520_camera u_sc520_watch_camera (
        .probe0(dbg_ae), .probe1(dbg_ag), .probe2(dbg_sensor_id),
        .probe3(dbg_cam_flags), .clk(S_24m_clk));
    ChipWatcher_sc520_mipi u_sc520_watch_mipi (
        .probe0(dbg_frames), .probe1(dbg_lines), .probe2(dbg_mipi_flags), .clk(S_csi_rx_clk));
    ChipWatcher_sc520_ddr u_sc520_watch_ddr (.probe0(dbg_ddr_flags), .clk(S_ddr_clk));
    ChipWatcher_sc520_awb u_sc520_watch_awb (
        .probe0(dbg_awb_r_gain), .probe1(dbg_awb_b_gain), .probe2(dbg_awb_stat_beats),
        .probe3(dbg_awb_total_beats), .clk(S_csi_rx_clk));
    ChipWatcher_sc520_write u_sc520_watch_write (
        .probe0(dbg_overflow_count), .probe1(dbg_frame_overflow),
        .probe2(dbg_previous_overflow), .clk(S_csi_rx_clk));
    ChipWatcher_sc520_read u_sc520_watch_read (
        .probe0(dbg_underflow_count), .probe1(dbg_read_corrupt), .clk(S_hdmi_pixel_clk));\n''',
        'awb.v':'', 'isp/awb/awb.v':'', 'video_in.v':'', 'video_out.v':''}
    for name,instance in instances.items():
        p=base/name;text=p.read_text(encoding='utf-8',errors='surrogateescape')
        text=text.replace(ATTR,'').replace('(* keep = "true", MARK_DEBUG = "TRUE" *)','(* keep = "true" *)')
        assert text.count('endmodule')==1,name
        p.write_text(text.replace('endmodule',instance+'endmodule',1),encoding='utf-8',errors='surrogateescape')
    awb_ports='output wire [19:0] O_debug_r_gain, O_debug_b_gain,\n    output wire [31:0] O_debug_stat_beats, O_debug_total_beats'
    export_specs={
        'awb.v':(r'(input\s+O_tready\s*)(\n\);)',awb_ports,
                 'assign O_debug_r_gain=in_r_r1; assign O_debug_b_gain=in_b_r1;\nassign O_debug_stat_beats=stat_beats; assign O_debug_total_beats=frame_beats_total;'),
        'isp/awb/awb.v':(r'(input\s+O_tready\s*)(\n\);)',awb_ports,
                 'assign O_debug_r_gain=in_r_r1; assign O_debug_b_gain=in_b_r1;\nassign O_debug_stat_beats=stat_beats; assign O_debug_total_beats=frame_beats_total;'),
        'isp/isp_top.v':(r'(output\s+I_tready\s*)(\n\);)',awb_ports,''),
        'video_in.v':(r'(input wire\s+I_ddr_user_ready\s*)(\n\);)',
                     'output wire [15:0] O_debug_overflow_count,\n    output wire O_debug_frame_overflow, O_debug_previous_overflow',
                     'assign O_debug_overflow_count=S_overflow_count;\nassign O_debug_frame_overflow=S_frame_overflow; assign O_debug_previous_overflow=S_previous_overflow;'),
        'video_out.v':(r'(output reg\[23:0\]\s+O_vdieo_data\s*)(\n\);)',
                      'output wire [15:0] O_debug_underflow_count,\n    output wire O_debug_read_corrupt',
                      'assign O_debug_underflow_count=S_underflow_count; assign O_debug_read_corrupt=S_read_corrupt;')}
    for name,(pattern,ports,assigns) in export_specs.items():
        p=base/name;text=p.read_text(encoding='utf-8',errors='surrogateescape')
        text,n=re.subn(pattern,lambda m:m.group(1).rstrip()+',\n    '+ports+m.group(2),text,count=1)
        assert n==1,(name,'debug port anchor')
        if assigns:text=text.replace('endmodule',assigns+'\nendmodule',1)
        if name=='isp/isp_top.v':
            connections=',\n    .O_debug_r_gain(O_debug_r_gain), .O_debug_b_gain(O_debug_b_gain),\n    .O_debug_stat_beats(O_debug_stat_beats), .O_debug_total_beats(O_debug_total_beats)'
            anchor='.O_tready(awb_O_tready)';assert anchor in text;text=text.replace(anchor,anchor+connections,1)
        p.write_text(text,encoding='utf-8',errors='surrogateescape')
    p=base/'design_top_wrapper.v';text=p.read_text(encoding='utf-8',errors='surrogateescape')
    additions={
        'u_isp_top':'.O_debug_r_gain(dbg_awb_r_gain), .O_debug_b_gain(dbg_awb_b_gain),\n.O_debug_stat_beats(dbg_awb_stat_beats), .O_debug_total_beats(dbg_awb_total_beats)',
        'u_video_in':'.O_debug_overflow_count(dbg_overflow_count),\n.O_debug_frame_overflow(dbg_frame_overflow), .O_debug_previous_overflow(dbg_previous_overflow)',
        'u_video_out':'.O_debug_underflow_count(dbg_underflow_count), .O_debug_read_corrupt(dbg_read_corrupt)'}
    for inst,connections in additions.items():
        pattern=r'(\b'+inst+r'\s*\([\s\S]*?)(\n\s*\);)'
        text,n=re.subn(pattern,lambda m:m.group(1).rstrip()+',\n'+connections+m.group(2),text,count=1)
        assert n==1,(inst,'debug connection anchor')
    p.write_text(text,encoding='utf-8',errors='surrogateescape')
    cores={'camera':[16,16,16,5], 'mipi':[32,11,4], 'ddr':[3],
           'awb':[20,20,32,32], 'write':[16,1,1], 'read':[16,1]}
    modules=[]
    for name,widths in cores.items():
        ports=[f'    input [{w-1}:0] probe{i}' for i,w in enumerate(widths)]+['    input clk']
        ones=','.join('1' for _ in widths)
        modules.append('// synthesis syn_black_box\nmodule ChipWatcher_sc520_'+name+' (\n'+',\n'.join(ports)+');\n'+f'''
    localparam string IP_TYPE = "ChipWatcher";
    localparam CWC_BUS_NUM = {len(widths)};
    localparam INPUT_PIPE_NUM = 1;
    localparam OUTPUT_PIPE_NUM = 1;
    localparam RAM_DATA_DEPTH = 1024;
    localparam CAPTURE_CONTROL = 0;
    localparam integer CWC_BUS_WIDTH [CWC_BUS_NUM-1:0] = {{{','.join(str(w) for w in widths)}}};
    localparam integer CWC_DATA_ENABLE [CWC_BUS_NUM-1:0] = {{{ones}}};
    localparam integer CWC_TRIG_ENABLE [CWC_BUS_NUM-1:0] = {{{ones}}};
endmodule
''')
    ip=Path(dest)/'td_project/al_ip/sc520_jtag_status';ip.mkdir(parents=True,exist_ok=True)
    (ip/'sc520_jtag_status.sv').write_text('\n'.join(modules),encoding='utf-8')
    # Observational cores have no functional outputs; simulators use port-only
    # stubs rather than TD's vendor-specific black-box parameter syntax.
    stubs=[]
    for name,widths in cores.items():
        ports=[f'input [{w-1}:0] probe{i}' for i,w in enumerate(widths)]+['input clk']
        stubs.append('module ChipWatcher_sc520_'+name+' ('+', '.join(ports)+'); endmodule')
    (ip/'sc520_jtag_status_sim.v').write_text('\n'.join(stubs)+'\n',encoding='utf-8')
    # Import through an IP-XACT fileSet with systemVerilogSource. TD's plain
    # Verilog project category parses even .sv files as Verilog-2001.
    import xml.etree.ElementTree as ET
    ns={'ipxact':'http://www.accellera.org/XMLSchema/IPXACT/1685-2014','anlogic':'http'}
    ET.register_namespace('ipxact',ns['ipxact']);ET.register_namespace('anlogic',ns['anlogic'])
    original=Path(dest)/'td_project/al_ip/ChipWatcher_mipi/ChipWatcher_mipi.xml'
    xml=original.read_text(encoding='utf-8').replace('ChipWatcher_mipi','sc520_jtag_status').replace('ChipWatcher_aef86b9bb9fc','ChipWatcher_sc520_camera')
    component=ET.fromstring(xml)
    ports=component.find('ipxact:model/ipxact:ports',ns)
    for child in list(ports):ports.remove(child)
    tag=lambda name:'{'+ns['ipxact']+'}'+name
    for i,w in enumerate(cores['camera']):
        port=ET.SubElement(ports,tag('port'));ET.SubElement(port,tag('name')).text=f'probe{i}'
        wire=ET.SubElement(port,tag('wire'));ET.SubElement(wire,tag('direction')).text='in'
        vector=ET.SubElement(ET.SubElement(wire,tag('vectors')),tag('vector'))
        ET.SubElement(vector,tag('left')).text=str(w-1);ET.SubElement(vector,tag('right')).text='0'
    port=ET.SubElement(ports,tag('port'));ET.SubElement(port,tag('name')).text='clk'
    ET.SubElement(ET.SubElement(port,tag('wire')),tag('direction')).text='in'
    files=component.find('ipxact:fileSets/ipxact:fileSet',ns)
    for child in list(files):
        if child.tag==tag('file'):files.remove(child)
    f=ET.SubElement(files,tag('file'));ET.SubElement(f,tag('name')).text='sc520_jtag_status.sv'
    ET.SubElement(f,tag('fileType')).text='systemVerilogSource'
    ET.SubElement(ET.SubElement(f,tag('vendorExtensions')),'{http}coreRTL').text='yes'
    ET.ElementTree(component).write(ip/'sc520_jtag_status.xml',encoding='UTF-8',xml_declaration=True)
    # Match the vendor IP exactly: each component has a real wrapper module,
    # its own coreRTL file, and its own typed IP-XACT ports. The wrapper is
    # needed for TD to retain ChipWatcher configuration across flow stages.
    xml_paths=[]
    for group,widths in cores.items():
        wrapper='sc520_watch_'+group;folder=Path(dest)/'td_project/al_ip'/wrapper
        (folder/'RTL').mkdir(parents=True,exist_ok=True)
        ports=[f'input [{w-1}:0] probe{i}' for i,w in enumerate(widths)]+['input clk']
        connections=[f'.probe{i}(probe{i})' for i in range(len(widths))]+['.clk(clk)']
        (folder/(wrapper+'.sv')).write_text('module '+wrapper+' ('+', '.join(ports)+');\nChipWatcher_sc520_'+group+' core ('+', '.join(connections)+');\nendmodule\n',encoding='utf-8')
        (folder/'RTL'/('ChipWatcher_sc520_'+group+'.sv')).write_text(modules[list(cores).index(group)],encoding='utf-8')
        obj=ET.fromstring(original.read_text(encoding='utf-8').replace('ChipWatcher_mipi',wrapper).replace('ChipWatcher_aef86b9bb9fc','ChipWatcher_sc520_'+group))
        ps=obj.find('ipxact:model/ipxact:ports',ns)
        for child in list(ps):ps.remove(child)
        for i,w in enumerate(widths):
            po=ET.SubElement(ps,tag('port'));ET.SubElement(po,tag('name')).text=f'probe{i}'
            wi=ET.SubElement(po,tag('wire'));ET.SubElement(wi,tag('direction')).text='in'
            ve=ET.SubElement(ET.SubElement(wi,tag('vectors')),tag('vector'))
            ET.SubElement(ve,tag('left')).text=str(w-1);ET.SubElement(ve,tag('right')).text='0'
        po=ET.SubElement(ps,tag('port'));ET.SubElement(po,tag('name')).text='clk'
        ET.SubElement(ET.SubElement(po,tag('wire')),tag('direction')).text='in'
        fs=obj.find('ipxact:fileSets/ipxact:fileSet',ns)
        for child in list(fs):
            if child.tag==tag('file'):fs.remove(child)
        for fn,core in [(wrapper+'.sv',False),('RTL/ChipWatcher_sc520_'+group+'.sv',True)]:
            f=ET.SubElement(fs,tag('file'));ET.SubElement(f,tag('name')).text=fn
            ET.SubElement(f,tag('fileType')).text='systemVerilogSource'
            if core:ET.SubElement(ET.SubElement(f,tag('vendorExtensions')),'{http}coreRTL').text='yes'
        path=folder/(wrapper+'.xml');ET.ElementTree(obj).write(path,encoding='UTF-8',xml_declaration=True)
        xml_paths.append(path.relative_to(Path(dest)/'td_project').as_posix())
    p=base/'design_top_wrapper.v';text=p.read_text(encoding='utf-8',errors='surrogateescape')
    text=re.sub(r'ChipWatcher_sc520_(\w+)(\s+u_sc520_watch_)',r'sc520_watch_\1\2',text)
    p.write_text(text,encoding='utf-8',errors='surrogateescape')
    for p in [Path(dest)/'td_project/camera_to_dsi_display.al',
              *Path(dest).glob('td_project/camera_to_dsi_display_Runs/*/camera_to_dsi_display.prj')]:
        tree=ET.parse(p);sources=tree.getroot().find('Source_Files');ipfiles=sources.find('IP_FILE')
        for index,xml_path in enumerate(xml_paths):
            entry=ET.SubElement(ipfiles,'File',Path=(xml_path if p.suffix=='.al' else '../../'+xml_path))
            info=ET.SubElement(entry,'FileInfo')
            for key,val in [('UsedInSyn','true'),('UsedInP&R','true'),('BelongTo','design_1'),('CompileOrder',str(99+index))]:
                ET.SubElement(info,'Attr',Name=key,Val=val)
        tree.write(p,encoding='UTF-8',xml_declaration=True)

if __name__=='__main__':
    import argparse
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('tree',type=Path)
    prepare(p.parse_args().tree)
