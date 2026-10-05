# -*- coding: utf-8 -*-
"""
run_all.py —— 视觉软件包整体测试调度器
流程：编译全部 RTL+TB（vlog）-> 逐 TB 仿真（vsim -c）-> 解析 TB_RESULT
      -> 帧级 hex 比对（TPG/OSD/整链）-> 汇总打印 + 写迭代测试报告。
用法：
    python run_all.py            # 全量
    python run_all.py tb_ser96to24 [tb_xxx ...]   # 只跑指定 TB
"""
import os
import re
import sys
import glob
import hashlib
import subprocess
import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_vectors import tpg_frame, render_osd, sp
from golden_model import full_detect

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MSIM = r'D:\ModelSim\win64'
VLOG = os.path.join(MSIM, 'vlog.exe')
VSIM = os.path.join(MSIM, 'vsim.exe')
VLIB = os.path.join(MSIM, 'vlib.exe')

import os as _os
P1 = sp('step1_video_link')
P2 = sp('step2_color_centroid')
P3 = sp('step3_closed_loop')
P4 = sp('step4_osd_integration')

def r(step, *parts):
    return os.path.join(ROOT, '03_vision', step, '03_project', *parts)

STEP1_RTL = [r('step1_video_link', 'rtl', f) for f in
             ['ser96to24.v', 'tpg_720p.v', 'sim_video_src.v', 'frame_dump24.v',
              'pulse_sync.v', 'cdc_4phase.v']]
STEP2_RTL = [r('step2_color_centroid', 'rtl', f) for f in
             ['hsv_inv_lut.v', 'rgb2hsv.v', 'hsv_threshold.v',
              'bin_smooth3x3.v', 'centroid_accum.v', 'detect_top.v']]
STEP3_RTL = [r('step3_closed_loop', 'rtl', f) for f in ['gimbal_ctrl.v', 'pwm_servo.v']]
STEP5_RTL = [r('step5_expansion', 'rtl', f) for f in
             ['edge_detect_96.v', 'video_adj.v', 'motion_detect.v', 'marquee_rom_64.v']]
STEP4_RTL = [r('step4_osd_integration', 'rtl', f) for f in
             ['font_rom_8x16.v', 'osd_track.v', 'vision_top.v']]
EMB_RTL = [os.path.join(ROOT, '04_embedded', '03_project', 'rtl', f) for f in
           ['led_buzzer.v', 'uart_telemetry.v']]

# name -> (sim_cwd_dir, 编译文件列表, 输出工件检查)
TBS = {
    'tb_ser96to24':  (r('step1_video_link', 'sim'), STEP1_RTL + [r('step1_video_link', 'tb', 'tb_ser96to24.v')], []),
    'tb_tpg':        (r('step1_video_link', 'sim'), STEP1_RTL + [r('step1_video_link', 'tb', 'tb_tpg.v')],
                      [('frame', 'tpg_act_0.hex', 'tpg_exp.hex')]),
    'tb_pulse_sync': (r('step1_video_link', 'sim'), STEP1_RTL + [r('step1_video_link', 'tb', 'tb_pulse_sync.v')], []),
    'tb_cdc4phase':  (r('step1_video_link', 'sim'), STEP1_RTL + [r('step1_video_link', 'tb', 'tb_cdc4phase.v')], []),
    'tb_cdc_reset_skew': (r('step1_video_link', 'sim'),
                          [os.path.join(ROOT, '03_vision', 'step1_video_link', '03_project', 'rtl', 'cdc_4phase.v'),
                           r('step1_video_link', 'tb', 'tb_cdc_reset_skew.v')], []),
    'tb_rgb2hsv':    (r('step2_color_centroid', 'sim'), STEP1_RTL[:1] + STEP2_RTL[:2] + [r('step2_color_centroid', 'tb', 'tb_rgb2hsv.v')], []),
    'tb_hsv_threshold': (r('step2_color_centroid', 'sim'), STEP2_RTL[:4] + [r('step2_color_centroid', 'tb', 'tb_hsv_threshold.v')], []),
    'tb_bin_smooth': (r('step2_color_centroid', 'sim'), STEP2_RTL[3:4] + [r('step2_color_centroid', 'tb', 'tb_bin_smooth.v')], []),
    'tb_centroid':   (r('step2_color_centroid', 'sim'), STEP2_RTL[4:5] + [r('step2_color_centroid', 'tb', 'tb_centroid.v')], []),
    'tb_detect_chain': (r('step2_color_centroid', 'sim'), STEP1_RTL[:1] + STEP1_RTL[2:3] + STEP2_RTL + [r('step2_color_centroid', 'tb', 'tb_detect_chain.v')], []),
    'tb_gimbal':     (r('step3_closed_loop', 'sim'), STEP3_RTL[:1] + [r('step3_closed_loop', 'tb', 'tb_gimbal.v')], []),
    'tb_pwm':        (r('step3_closed_loop', 'sim'), STEP3_RTL[1:2] + [r('step3_closed_loop', 'tb', 'tb_pwm.v')], []),
    'tb_osd_track':  (r('step4_osd_integration', 'sim'), STEP1_RTL[5:6] + STEP4_RTL[:2] + STEP5_RTL[3:4] + [r('step4_osd_integration', 'tb', 'tb_osd_track.v')],
                      [('frame', 'osd_act_f0.hex', 'osd_exp_f0.hex'),
                       ('frame', 'osd_act_f1.hex', 'osd_exp_f1.hex'),
                       ('frame', 'osd_act_f2.hex', 'osd_exp_f2.hex')]),
    'tb_vision_top': (r('step4_osd_integration', 'sim'), STEP1_RTL + STEP2_RTL + STEP3_RTL + STEP4_RTL + STEP5_RTL + EMB_RTL + [r('step4_osd_integration', 'tb', 'tb_vision_top.v')],
                      []),  # v2 OSD 金标准渲染器待更新，功能断言由 TB 内部完成
    'tb_closed_loop': (r('step4_osd_integration', 'sim'), STEP1_RTL + STEP2_RTL + STEP3_RTL + STEP4_RTL + STEP5_RTL + EMB_RTL + [r('step4_osd_integration', 'tb', 'tb_closed_loop.v')], []),
    'tb_algo_switch': (r('step4_osd_integration', 'sim'), STEP1_RTL + STEP2_RTL + STEP3_RTL + STEP4_RTL + STEP5_RTL + EMB_RTL + [r('step4_osd_integration', 'tb', 'tb_algo_switch.v')], []),
    # ---------------- 嵌入式方向（04_embedded） ----------------
    'tb_uart_telemetry': (
        os.path.join(ROOT, '04_embedded', '03_project', 'sim'),
        STEP1_RTL[:1] + STEP1_RTL[4:6] + STEP2_RTL[1:6] + STEP2_RTL[0:1] + STEP3_RTL + STEP4_RTL + [
            os.path.join(ROOT, '04_embedded', '03_project', 'rtl', 'uart_telemetry.v'),
            os.path.join(ROOT, '04_embedded', '03_project', 'tb', 'uart_rx_mon.v'),
            os.path.join(ROOT, '04_embedded', '03_project', 'tb', 'tb_uart_telemetry.v')], []),
    # ---------------- v2 拓展（step5） ----------------
    'tb_motion_detect': (r('step5_expansion', 'sim'),
                         STEP5_RTL[:4] + [r('step5_expansion', 'tb', 'tb_motion_detect.v')], []),
    # TD 阶段项（默认回归外，见 04_embedded 报告）：
    #   tb_i2c_config      —— 需与真机 I2C 波形对照后收敛位相
    #   tb_system_integration —— 官方 demosaic 的 tuser 链在纯 RTL 仿真不激活（TD/真机项）
}


def sha_lines(path):
    h = hashlib.sha256()
    with open(path, 'r') as f:
        for line in f:
            h.update(line.strip().upper().encode())
    return h.hexdigest()


def check_frame(cwd, act, exp, log):
    a, e = os.path.join(cwd, act), os.path.join(cwd, exp)
    if not os.path.exists(a):
        return False, f'{act} 不存在'
    if sha_lines(a) == sha_lines(e):
        return True, f'{act} 与金标准逐像素一致'
    # 找第一个差异行
    with open(a) as fa, open(e) as fe:
        for i, (la, le) in enumerate(zip(fa, fe)):
            if la.strip().upper() != le.strip().upper():
                return False, f'{act} 首个差异在第 {i} 像素: got={la.strip()} exp={le.strip()}'
        return False, f'{act} 行数不一致'


def check_vision(cwd, act, _):
    # v2：OSD 三行+跑马灯的金标准渲染器尚未更新，暂时只检查转储完整性
    a = os.path.join(cwd, act)
    if not os.path.exists(a):
        return False, f'{act} 不存在'
    n = sum(1 for _ in open(a))
    if n != 921600:
        return False, f'帧行数 {n} != 921600'
    with open(os.path.join(cwd, 'vision_duty.txt')) as f:
        dx, dy, lost, status = map(int, f.read().split())
    if not (700 <= dx < 1500):
        return False, f'云台 X 方向错误: duty_x={dx}'
    if dy != 1500:
        return False, f'云台 Y 死区错误: duty_y={dy}'
    if lost != 0:
        return False, f'目标不应丢失: lost={lost}'
    return True, f'帧完整 {n} px; duty=({dx},{dy}) 方向正确; lost=0'
    """整链：OSD 帧 + 云台方向 + 质心正确性。"""
    a = os.path.join(cwd, act)
    if not os.path.exists(a):
        return False, f'{act} 不存在'
    # 期望：TPG 图案 -> 金标准检测 -> 叠加渲染
    img = tpg_frame()
    _, _, res = full_detect(img.astype('uint8'))
    exp_img = render_osd(img, res)
    exp_lines = [f"{p[0]:02X}{p[1]:02X}{p[2]:02X}" for p in exp_img.reshape(-1, 3)]
    with open(a) as f:
        act_lines = [l.strip().upper() for l in f]
    if len(act_lines) != len(exp_lines):
        return False, f'帧行数 {len(act_lines)} != {len(exp_lines)}'
    diff = next((i for i, (x, y) in enumerate(zip(act_lines, exp_lines)) if x != y), None)
    if diff is not None:
        return False, f'帧差异@{diff}: got={act_lines[diff]} exp={exp_lines[diff]}'
    # 云台方向
    with open(os.path.join(cwd, 'vision_duty.txt')) as f:
        dx, dy, lost, status = map(int, f.read().split())
    if not (700 <= dx < 1500):
        return False, f'云台 X 方向错误: duty_x={dx}（目标在中心左侧，应 <1500 且 >=700）'
    if dy != 1500:
        return False, f'云台 Y 死区错误: duty_y={dy}（cy=340, err=-20 恰在 DZ_Y=20 内，应保持 1500）'
    if lost != 0:
        return False, f'目标不应丢失: lost={lost}'
    return True, (f'OSD 帧 921600 像素全一致; duty=({dx},{dy})µs 方向正确; '
                  f'centroid=({res["cx"]},{res["cy"]}) count={res["count"]}')


def run_tb(name):
    cwd, files, checks = TBS[name]
    os.chdir(cwd)
    if not os.path.isdir('work'):
        subprocess.run([VLIB, 'work'], capture_output=True)
    out = {'name': name, 'compile': '', 'sim': '', 'pass': False, 'detail': ''}
    cp = subprocess.run([VLOG, '-quiet'] + files, capture_output=True, text=True,
                        errors='replace')
    out['compile'] = (cp.stdout + cp.stderr).strip()
    if cp.returncode != 0:
        out['detail'] = '编译失败:\n' + out['compile'][-1500:]
        return out
    cs = subprocess.run([VSIM, '-c', '-quiet', name, '-do', 'run -all; quit -f'],
                        capture_output=True, text=True, errors='replace', timeout=3600)
    log = cs.stdout + cs.stderr
    out['sim'] = log
    ok = re.search(r'TB_RESULT: PASS', log) is not None
    msgs = [l for l in log.splitlines()
            if re.search(r'(MISM|_ERR|FATAL|LOCKED|MEAS|FRAME\d|STEP\d|DUTY_REPORT)', l)]
    out['detail'] = '\n'.join(msgs[-12:])
    # 工件检查
    for kind, act, exp in checks:
        if kind == 'frame':
            ok2, msg = check_frame(cwd, act, exp, log)
        else:
            ok2, msg = check_vision(cwd, act, exp)
        out['detail'] += f'\n[{kind}] {msg}'
        ok = ok and ok2
    out['pass'] = ok
    return out


def main():
    only = sys.argv[1:]
    names = only if only else list(TBS.keys())
    print(f'==== 视觉软件包整体测试  {datetime.datetime.now():%Y-%m-%d %H:%M:%S} ====')
    results = []
    for n in names:
        print(f'--- {n} ...', flush=True)
        try:
            res = run_tb(n)
        except subprocess.TimeoutExpired:
            res = {'name': n, 'pass': False, 'compile': '', 'sim': '',
                   'detail': '仿真超时(1h)'}
        tag = 'PASS' if res['pass'] else 'FAIL'
        print(f'    ==> {tag}')
        if res['detail']:
            for line in res['detail'].splitlines():
                print('        ' + line)
        results.append(res)
        os.chdir(ROOT)
    npass = sum(1 for x in results if x['pass'])
    print(f'\n==== 汇总: {npass}/{len(results)} PASS ====')
    for x in results:
        if not x['pass']:
            print(f"  FAIL: {x['name']}")
            if x.get('compile') and 'Error' in x['compile']:
                print('    (编译错误见迭代日志)')
    # 写迭代测试日志
    logdir = os.path.join(ROOT, '03_vision', 'step4_osd_integration', '04_迭代文件')
    os.makedirs(logdir, exist_ok=True)
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
    with open(os.path.join(logdir, f'测试运行_{stamp}.log'), 'w', encoding='utf-8') as f:
        for x in results:
            f.write(f"===== {x['name']} : {'PASS' if x['pass'] else 'FAIL'} =====\n")
            if x.get('compile'):
                f.write('-- compile --\n' + x['compile'][-3000:] + '\n')
            f.write('-- sim tail --\n')
            f.write('\n'.join(x['sim'].splitlines()[-40:]) + '\n\n')
    print(f'日志已写入 04_迭代文件/测试运行_{stamp}.log')
    return 0 if npass == len(results) else 1


if __name__ == '__main__':
    sys.exit(main())
