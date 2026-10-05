# -*- coding: utf-8 -*-
"""第二轮修复补丁（一次性使用后可删）"""
import io

def patch(path, pairs, must=True):
    s = io.open(path, encoding='utf-8').read()
    for old, new in pairs:
        if old not in s:
            if must:
                raise SystemExit(f"NOT FOUND in {path}:\n{old[:120]}")
            continue
        s = s.replace(old, new)
    io.open(path, 'w', encoding='utf-8').write(s)
    print('patched', path)

ROOT = r'D:\fpga-ptz-tracker'

# A. centroid_accum：除法快照
patch(ROOT + r'\03_vision\step2_color_centroid\03_project\rtl\centroid_accum.v', [
    ("""    reg [5:0]  bit_cnt;      // 32 位商逐位恢复""",
     """    reg [5:0]  bit_cnt;      // 32 位商逐位恢复
    // 除法快照：tick 时刻定格，下一帧 sof 清零累加器不影响本次结果
    reg [31:0] snap_sumx, snap_sumy;
    reg [20:0] snap_cnt;
    reg [10:0] snap_minx, snap_maxx;
    reg [9:0]  snap_miny, snap_maxy;"""),
    ("""                S_IDLE: if (tick_r) begin
                    if (cnt < MIN_PIXELS) begin""",
     """                S_IDLE: if (tick_r) begin
                    snap_sumx <= sum_x; snap_sumy <= sum_y;
                    snap_cnt  <= cnt;
                    snap_minx <= bmin_x; snap_maxx <= bmax_x;
                    snap_miny <= bmin_y; snap_maxy <= bmax_y;
                    if (cnt < MIN_PIXELS) begin"""),
    ("""                        if (st == S_DIV_X) begin
                            dividend <= sum_y;              // 切换 Y 轴""",
     """                        if (st == S_DIV_X) begin
                            dividend <= snap_sumy;          // 切换 Y 轴（用快照）"""),
    ("""                if (cnt >= MIN_PIXELS) begin
                    O_target_valid <= 1'b1;
                    O_cx <= q_x[10:0];
                    O_cy <= q_y[10:0];
                    O_count <= cnt;
                    O_min_x <= bmin_x; O_max_x <= bmax_x;
                    O_min_y <= bmin_y; O_max_y <= bmax_y;""",
     """                if (snap_cnt >= MIN_PIXELS) begin
                    O_target_valid <= 1'b1;
                    O_cx <= q_x[10:0];
                    O_cy <= q_y[10:0];
                    O_count <= snap_cnt;
                    O_min_x <= snap_minx; O_max_x <= snap_maxx;
                    O_min_y <= snap_miny; O_max_y <= snap_maxy;"""),
    ("""                    O_count <= cnt;
                    O_min_x <= 11'd0; O_max_x <= 11'd0;""",
     """                    O_count <= snap_cnt;
                    O_min_x <= 11'd0; O_max_x <= 11'd0;"""),
])

# B. 生成器：迷你帧块坐标收进 128 宽
patch(ROOT + r'\tools\gen_vectors.py', [
    ("    m[20:60, 56:146] = 1\n    masks.append(m)                                   # 帧0: 90x40 实心块",
     "    m[20:60, 30:120] = 1\n    masks.append(m)                                   # 帧0: 90x40 实心块"),
])

# C. tb_pwm：去语句标签
patch(ROOT + r'\03_vision\step3_closed_loop\03_project\tb\tb_pwm.v', [
    ("""    integer cnt_x, cnt_y, len, mism = 0, meas = 0;

    task measure_phase;
        input [16:0] exp_x;
        input [16:0] exp_y;
        begin
            @(posedge tick);
            cnt_x = 0; cnt_y = 0; len = 0;
            // 统计一个完整周期（到下一个 tick 为止）
            forever begin
                @(posedge clk);
                if (pwm_x) cnt_x = cnt_x + 1;
                if (pwm_y) cnt_y = cnt_y + 1;
                len = len + 1;
                if (tick) begin
                    // 本拍即下一周期起点，len 已含 1,000,000 拍
                    if ((cnt_x !== exp_x) || (cnt_y !== exp_y) || (len != 1000000)) begin
                        $display("MISM meas=%0d got x=%0d y=%0d len=%0d | exp x=%0d y=%0d len=1000000",
                                 meas, cnt_x, cnt_y, len, exp_x, exp_y);
                        mism = mism + 1;
                    end else begin
                        $display("MEAS%0d OK x=%0d y=%0d len=%0d", meas, cnt_x, cnt_y, len);
                    end
                    meas = meas + 1;
                    disable forever_block;
                end
            end
            forever_block: ;
        end
    endtask""",
     """    integer cnt_x, cnt_y, len, mism = 0, meas = 0;
    reg done;

    task measure_phase;
        input [16:0] exp_x;
        input [16:0] exp_y;
        begin
            @(posedge tick);
            cnt_x = 0; cnt_y = 0; len = 0;
            done = 0;
            while (!done) begin
                @(posedge clk);
                if (pwm_x) cnt_x = cnt_x + 1;
                if (pwm_y) cnt_y = cnt_y + 1;
                len = len + 1;
                if (tick) done = 1;
            end
            if ((cnt_x !== exp_x) || (cnt_y !== exp_y) || (len != 1000000)) begin
                $display("MISM meas=%0d got x=%0d y=%0d len=%0d | exp x=%0d y=%0d len=1000000",
                         meas, cnt_x, cnt_y, len, exp_x, exp_y);
                mism = mism + 1;
            end else begin
                $display("MEAS%0d OK x=%0d y=%0d len=%0d", meas, cnt_x, cnt_y, len);
            end
            meas = meas + 1;
        end
    endtask"""),
])

# D. 仿真模块补 timescale
for rel in [r'\03_vision\step1_video_link\03_project\rtl\sim_video_src.v',
            r'\03_vision\step1_video_link\03_project\rtl\frame_dump24.v']:
    p = ROOT + rel
    s = io.open(p, encoding='utf-8').read()
    if '`timescale' not in s:
        io.open(p, 'w', encoding='utf-8').write('`timescale 1ns/1ps\n' + s)
        print('timescale added', rel)

# E. tb_osd_track 标量位选
patch(ROOT + r'\03_vision\step4_osd_integration\03_project\tb\tb_osd_track.v', [
    ("pack = {v_in[0], 3'd0,", "pack = {v_in, 3'd0,"),
])

# F. tb_closed_loop 重复声明
patch(ROOT + r'\03_vision\step4_osd_integration\03_project\tb\tb_closed_loop.v', [
    ("""        .O_duty_x_us(duty_x), .O_duty_y_us(),
        .O_lost_cnt(), .O_status());
    wire [12:0] duty_x = dut.O_duty_x_us;""",
     """        .O_duty_x_us(duty_x), .O_duty_y_us(),
        .O_lost_cnt(), .O_status());"""),
    ("""    wire [23:0] osd_data;
    wire        osd_valid, osd_sof, osd_eol;""",
     """    wire [23:0] osd_data;
    wire        osd_valid, osd_sof, osd_eol;
    wire [12:0] duty_x;"""),
])

# G. gimbal_ctrl：无效拍 dz/lim 清零改阻塞
patch(ROOT + r'\03_vision\step3_closed_loop\03_project\rtl\gimbal_ctrl.v', [
    ("""            end else begin
                lost = 1'b1;              // 保持脉宽，只计丢失
                dzx <= 1'b0; dzy <= 1'b0; limx <= 1'b0; limy <= 1'b0;""",
     """            end else begin
                lost = 1'b1;              // 保持脉宽，只计丢失
                dzx = 1'b0; dzy = 1'b0; limx = 1'b0; limy = 1'b0;"""),
    ("""                lost   = 1'b1;
                dzx <= 1'b0; dzy <= 1'b0; limx <= 1'b0; limy <= 1'b0;
                O_lost_cnt <= 16'd0;""",
     """                lost   = 1'b1;
                dzx = 1'b0; dzy = 1'b0; limx = 1'b0; limy = 1'b0;
                O_lost_cnt <= 16'd0;"""),
])

print('ALL PATCHES OK')
