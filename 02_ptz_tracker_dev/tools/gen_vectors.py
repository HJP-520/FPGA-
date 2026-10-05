# -*- coding: utf-8 -*-
"""
gen_vectors.py —— 生成全部测试向量（ModelSim $readmemh 格式）与期望输出，
并自动生成两份 RTL：hsv_inv_lut.v（HSV 倒数查找表）、font_rom_8x16.v（OSD 字库）。
所有期望值由 golden_model.py 位精确算出。用法：
    python gen_vectors.py all       # 生成全部
    python gen_vectors.py list      # 列出各目标
"""
import os
import sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from golden_model import (IMG_W, IMG_H, CENTER_X, CENTER_Y, HSV_PRESETS,
                          rgb_to_hsv, hsv_threshold, smooth3x3_majority,
                          centroid_bbox, gimbal_ctrl_step, full_detect)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RNG = np.random.default_rng(20260918)  # 固定种子，保证可复现


def w(path, lines):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    print(f"  写 {path} ({len(lines)} 行)")


def sp(step):
    return os.path.join(ROOT, '03_vision', step, '03_project')


# ---------------- 生成 RTL：HSV 倒数 LUT ----------------
def gen_inv_lut():
    lines = ["// 自动生成：tools/gen_vectors.py  inv[d]=floor(3840/d) d=1..255",
             "// 供 rgb2hsv.v 求色调用，综合为 Block ROM",
             "module hsv_inv_lut (", "    input  wire [7:0]  I_d,", "    output reg  [11:0] O_inv", ");",
             "always @(*) begin", "    case (I_d)"]
    for d in range(1, 256):
        lines.append(f"        8'd{d}: O_inv = 12'd{3840 // d};")
    lines += ["        default: O_inv = 12'd0;", "    endcase", "end", "endmodule"]
    w(os.path.join(sp('step2_color_centroid'), 'rtl', 'hsv_inv_lut.v'), lines)


# ---------------- 生成 RTL：8x16 字库 ----------------
FONT_CHARS = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ:.-+/"
FONT_TEXTS = ["LOCK", "LOST", "TRK", "X", "Y"]


_FONT_CACHE = {}


def gen_font_glyph(ch):
    """单个字符的 8x16 点阵（带缓存），与 font_rom_8x16.v 逐位一致。"""
    if not _FONT_CACHE:
        import cv2
        for c in FONT_CHARS:
            img = np.zeros((16, 8), dtype=np.uint8)
            scale = 0.55 if c != ' ' else 0.1
            t = cv2.putText(img, c, (0, 14), cv2.FONT_HERSHEY_SIMPLEX,
                            scale, 255, 1, cv2.LINE_AA)
            _FONT_CACHE[c] = (t >= 110).astype(np.uint8)
    return _FONT_CACHE.get(ch, np.zeros((16, 8), dtype=np.uint8))


def gen_font():
    """cv2 Hershey 轮廓字渲染到 8x16 点阵，阈值化为位图 -> case 表 ROM。"""
    glyph = {ch: gen_font_glyph(ch) for ch in FONT_CHARS}
    lines = ["// 自动生成：tools/gen_vectors.py (cv2 Hershey->8x16 点阵)",
             "// 地址 {char[7:0], row[3:0]} -> 该行 8 位点阵（MSB=最左像素）",
             "module font_rom_8x16 (", "    input  wire [11:0] I_addr,",
             "    output reg  [7:0]  O_bits", ");", "always @(*) begin",
             "    case (I_addr)"]
    for ch in FONT_CHARS:
        bits = glyph[ch]
        for r in range(16):
            val = 0
            for c in range(8):
                val = (val << 1) | int(bits[r, c])
            lines.append(f"        12'h{(ord(ch) << 4 | r):03X}: O_bits = 8'h{val:02X};  // '{ch}' row{r}")
    lines += ["        default: O_bits = 8'h00;", "    endcase", "end", "endmodule"]
    w(os.path.join(sp('step4_osd_integration'), 'rtl', 'font_rom_8x16.v'), lines)
    return glyph


# ---------------- 场景生成 ----------------
def scene_red_square(x0=560, y0=300, size=90, noise=0):
    img = np.full((IMG_H, IMG_W, 3), 128, dtype=np.uint8)      # 灰底
    img[y0:y0 + size, x0:x0 + size] = (224, 32, 32)            # 红块 RGB
    if noise:
        ys = RNG.integers(0, IMG_H, noise)
        xs = RNG.integers(0, IMG_W, noise)
        cols = RNG.integers(0, 256, (noise, 3))
        img[ys, xs] = cols
    return img


def scene_two_objects():
    img = np.full((IMG_H, IMG_W, 3), 100, dtype=np.uint8)
    img[200:320, 300:420] = (224, 32, 32)     # 红
    img[430:560, 800:940] = (200, 32, 200)    # 品红（3扇区算法会混入 H=0 扇区，靠 s_lo 抑制：S=168 仍过 -> 检验质心偏移告警场景）
    return img


def scene_small_target():
    img = np.full((IMG_H, IMG_W, 3), 128, dtype=np.uint8)
    img[100:115, 100:115] = (224, 32, 32)     # 15x15=225 >= MIN_PIXELS
    return img


def scene_tiny_target():
    img = np.full((IMG_H, IMG_W, 3), 128, dtype=np.uint8)
    img[300:303, 300:303] = (224, 32, 32)     # 9 px < MIN_PIXELS -> invalid
    return img


def scene_to_beats(img):
    """图像 -> 96bit(4像素/拍) AXI-S beat hex 行 + tuser/tlast 标记行。"""
    flat = img.reshape(-1, 3)
    lines, flags = [], []
    n = flat.shape[0]
    for i in range(0, n, 4):
        px = flat[i:i + 4]
        while len(px) < 4:
            px = np.vstack([px, px[-1]])
        val = 0
        for k, (r, g, b) in enumerate(px):
            val |= (int(r) << (88 - 24 * k)) | (int(g) << (80 - 24 * k)) | (int(b) << (72 - 24 * k))
        lines.append(f"{val:024X}")
        beat_idx = (i // 4) % (IMG_W // 4)
        line_idx = (i // 4) // (IMG_W // 4)
        tuser = 1 if i == 0 else 0
        tlast = 1 if beat_idx == (IMG_W // 4 - 1) else 0
        flags.append(f"{(tuser << 1) | tlast:X}")   # 单字符（2bit 向量限 1 位数字）
    return lines, flags



TPG_BARS = [(64,64,64),(128,128,128),(192,192,192),(224,224,224),
            (32,32,224),(32,224,32),(16,96,16),(16,16,96)]

def tpg_frame(box_x=500, box_y=300, box_en=True, box_w=80, box_h=80):
    """位精确复刻 tpg_720p.v 的输出图案。"""
    img = np.zeros((IMG_H, IMG_W, 3), dtype=np.int64)
    for x in range(IMG_W):
        c = TPG_BARS[min(x // 160, 7)]
        img[:, x, :] = c
    if box_en:
        img[box_y:box_y+box_h, box_x:box_x+box_w] = (224, 32, 32)
    return img


def gen_tb_tpg():
    d = os.path.join(sp('step1_video_link'), 'sim')
    img = tpg_frame()
    w(os.path.join(d, 'tpg_exp.hex'),
      [f"{p[0]:02X}{p[1]:02X}{p[2]:02X}" for p in img.reshape(-1, 3)])
    return img


# ---------------- 各 TB 向量 ----------------

def gen_tb_rgb2hsv():
    d = os.path.join(sp('step2_color_centroid'), 'sim')
    n = 10000
    rgb = RNG.integers(0, 256, (n, 3))
    corners = np.array([[0, 0, 0], [255, 255, 255], [255, 0, 0], [0, 255, 0],
                        [0, 0, 255], [255, 255, 0], [0, 255, 255], [255, 0, 255],
                        [128, 128, 128], [224, 32, 32]], dtype=np.int64)
    rgb = np.vstack([corners, rgb])
    h, s, v = rgb_to_hsv(rgb[:, 0], rgb[:, 1], rgb[:, 2])
    w(os.path.join(d, 'rgb2hsv_in.hex'), [f"{r:02X}{g:02X}{b:02X}" for r, g, b in rgb])
    w(os.path.join(d, 'rgb2hsv_exp.hex'), [f"{hh:03X}{ss:02X}{vv:02X}" for hh, ss, vv in zip(h, s, v)])


def gen_tb_threshold():
    d = os.path.join(sp('step2_color_centroid'), 'sim')
    n = 4000
    h = RNG.integers(0, 360, n)
    s = RNG.integers(0, 256, n)
    v = RNG.integers(0, 256, n)
    pres = np.arange(n) % 8
    m = np.array([hsv_threshold(h[i], s[i], v[i], pres[i]) for i in range(n)])
    w(os.path.join(d, 'threshold_in.hex'),
      [f"{hh:03X}{ss:02X}{vv:02X}{p:01X}" for hh, ss, vv, p in zip(h, s, v, pres)])
    w(os.path.join(d, 'threshold_exp.hex'), [str(int(x)) for x in m])


def gen_tb_smooth():
    d = os.path.join(sp('step2_color_centroid'), 'sim')
    W, H, FRAMES = 64, 48, 4
    masks = (RNG.random((FRAMES, H, W)) < 0.35).astype(np.uint8)
    for f in range(FRAMES):
        y0, x0 = 10 + f * 3, 8 + f * 5
        masks[f, y0:y0 + 12, x0:x0 + 14] = 1
    lines_in, lines_exp = [], []
    for f in range(FRAMES):
        sm = smooth3x3_majority(masks[f], W, H)
        lines_in += [f"{int(x)}" for x in masks[f].ravel()]
        lines_exp += [f"{int(x)}" for x in sm.ravel()]
    w(os.path.join(d, 'smooth_in.hex'), lines_in)
    w(os.path.join(d, 'smooth_exp.hex'), lines_exp)
    with open(os.path.join(d, 'smooth_geo.txt'), 'w') as fh:
        fh.write(f"{W} {H} {FRAMES}\n")


def gen_tb_centroid():
    """迷你几何（128x72）质心单元测试：实心块 / 噪声+小块 / 微块(无效)。"""
    from golden_model import MIN_PIXELS as MP
    d = os.path.join(sp('step3_placeholder'), 'sim')  # 占位，下面覆盖
    d = os.path.join(sp('step2_color_centroid'), 'sim')
    W, H = 128, 72
    masks = []
    m = np.zeros((H, W), dtype=np.uint8)
    m[20:60, 30:120] = 1
    masks.append(m)                                   # 帧0: 90x40 实心块
    m2 = np.zeros((H, W), dtype=np.uint8)
    ys = RNG.integers(0, H, 150)
    xs = RNG.integers(0, W, 150)
    m2[ys, xs] = 1
    m2[10:20, 90:120] = 1
    masks.append(m2)                                  # 帧1: 噪声+30x10 块
    m3 = np.zeros((H, W), dtype=np.uint8)
    m3[30:33, 30:33] = 1                              # 帧2: 9px < 门限
    masks.append(m3)
    lines_in, lines_exp = [], []
    for m in masks:
        r = centroid_bbox(m, W, H, MP)
        lines_in += [f"{int(x)}" for x in m.ravel()]
        lines_exp.append(f"{r['valid']:X}{r['count']:05X}{r['cx']:03X}{r['cy']:03X}"
                         f"{r['min_x']:03X}{r['max_x']:03X}{r['min_y']:03X}{r['max_y']:03X}")
    w(os.path.join(d, 'centroid_in.hex'), lines_in)
    w(os.path.join(d, 'centroid_exp.txt'), lines_exp)
    with open(os.path.join(d, 'centroid_geo.txt'), 'w') as fh:
        fh.write(f"{W} {H}" + chr(10))


def gen_tb_chain():
    """detect 链 TB：真实场景（灰底+红块+噪声+品红干扰物），3 帧。"""
    d = os.path.join(sp('step2_color_centroid'), 'sim')
    scenes = [scene_red_square(560, 300, 90, noise=1500),
              scene_two_objects(),
              scene_small_target()]
    beats, flags, exp = [], [], []
    for img in scenes:
        b, f = scene_to_beats(img)
        beats += b
        flags += f
        _, sm, r = full_detect(img)
        exp.append(f"{r['valid']:X}{r['count']:05X}{r['cx']:03X}{r['cy']:03X}"
                   f"{r['min_x']:03X}{r['max_x']:03X}{r['min_y']:03X}{r['max_y']:03X}")
    w(os.path.join(d, 'chain_beats.hex'), beats)
    w(os.path.join(d, 'chain_flags.hex'), flags)
    w(os.path.join(d, 'chain_exp.txt'), exp)


def gen_tb_gimbal():
    d = os.path.join(sp('step3_closed_loop'), 'sim')
    rows, exp = [], []
    # 轴参数（与 gimbal_ctrl.v 默认参数一致）
    KPX, DZX, SLEW, SMIN, SMAX, CX = 20, 25, 100, 700, 2300, CENTER_X
    KPY, DZY, CY = 18, 20, CENTER_Y
    dx = dy = 1500
    dpx = dpy = 0
    lost = 1
    cases = [(1, 840, 360), (1, 840, 360), (1, 900, 300), (1, 700, 200),
             (1, 641, 361), (0, 0, 0), (0, 0, 0), (1, 100, 600),
             (1, 640, 360), (1, 660, 350)]
    for valid, cx, cy in cases:
        rows.append(f"{valid:X}{cx:03X}{cy:03X}")
        if valid:
            lost = 0
            ex, ey = cx - CX, cy - CY
            ndx = gimbal_ctrl_step(ex, dx, KPX, 0, 0, DZX, SLEW, SMIN, SMAX)
            ndy = gimbal_ctrl_step(ey, dy, KPY, 0, 0, DZY, SLEW, SMIN, SMAX)
            dx, dy = ndx, ndy
            dpx = 1 if abs(ex) <= DZX else 0
            dpy = 1 if abs(ey) <= DZY else 0
        else:
            lost += 1
            dpx = dpy = 0
        exp.append(f"{dx:03X}{dy:03X}{lost:04X}{dpx:X}{dpy:X}")
    w(os.path.join(d, 'gimbal_stim.txt'), rows)
    w(os.path.join(d, 'gimbal_exp.txt'), exp)


def render_osd(img, state, disp_cnt):
    """位精确复刻 osd_track.v v3（双缓冲版）的叠加规则。
    state: None = 空状态（复位影子，无文本无框，跑马灯照滚）；
           dict = {valid,cx,cy,min_x,max_x,min_y,max_y, lat,preset,algo,
                   mot: None 或 dict(cnt,valid,min_x,max_x,min_y,max_y)}
    disp_cnt: 帧序计数器（RTL 在 sof 拍 +1，帧 0 绘制期间值为 1）。
    绘制优先级 文字L1>L2>跑马灯>十字>目标框>运动框>底图。"""
    out = img.copy().astype(np.int64)
    H, W = img.shape[:2]
    TXT_X0, TXT_Y0, TXT2_Y0, TXT3_Y0 = 16, 16, 40, 64

    def glyph_bits(ch):
        return gen_font_glyph(ch)

    def draw_text(out, chars, x0_band, y0_band):
        for i, ch in enumerate(chars):
            if ch == ' ':
                continue
            bits = glyph_bits(ch)
            gx, gy = x0_band + i * 8, y0_band
            for ry in range(16):
                row_bits = bits[ry]
                for rx in range(8):
                    if row_bits[rx]:
                        yy, xx = gy + ry, gx + rx
                        if yy < H and xx < W:
                            out[yy, xx] = (255, 255, 255)

    # ---- 文本内容（逐字对应 RTL txt1/txt2 赋值） ----
    if state is not None:
        v = state['valid']
        algo = state.get('algo', 0)
        pre = state.get('preset', 0)
        cx, cy = state['cx'], state['cy']
        t1 = ('EDG' if algo else 'TRK') + str(pre) + ' '
        t1 += 'LOCK' if v else 'LOST'
        t1 += ' X' + (f"{cx:04d}" if v else '----') + 'Y' + (f"{cy:04d}" if v else '----')
        lat = min(state.get('lat', 0), 99)
        br, ct = state.get('bright', 0), state.get('contrast', 64)
        b_abs = (~br + 1) & 0x7F if br & 0x40 else br
        mcnt = min(state.get('mcnt', 0), 9999)
        t2 = (f"D{lat:02d} B{'-' if br & 0x40 else '+'}{b_abs:02d} "
              f"C{ct >> 3:02d} M{mcnt:04d} ")
        draw_text(out, t1.ljust(20), TXT_X0, TXT_Y0)
        draw_text(out, t2.ljust(20), TXT_X0, TXT2_Y0)

        if v:
            x0, x1, y0, y1 = state['min_x'], state['max_x'], state['min_y'], state['max_y']
            rows = sorted(set([y0, min(y0 + 1, y1), max(y1 - 1, y0), y1]))
            cols = sorted(set([x0, min(x0 + 1, x1), max(x1 - 1, x0), x1]))
            for y in rows:
                if 0 <= y < H:
                    out[y, max(x0, 0):min(x1 + 1, W)] = (255, 0, 0)
            for x in cols:
                if 0 <= x < W:
                    out[max(y0, 0):min(y1 + 1, H), x] = (255, 0, 0)
            for d in list(range(-12, -2)) + list(range(3, 13)):
                if 0 <= cy < H and 0 <= cx + d < W:
                    out[cy, cx + d] = (0, 255, 0)
                if 0 <= cx < W and 0 <= cy + d < H:
                    out[cy + d, cx] = (0, 255, 0)
        mot = state.get('mot')
        if mot and mot.get('valid'):
            x0, x1, y0, y1 = mot['min_x'], mot['max_x'], mot['min_y'], mot['max_y']
            rows = sorted(set([y0, min(y0 + 1, y1), max(y1 - 1, y0), y1]))
            cols = sorted(set([x0, min(x0 + 1, x1), max(x1 - 1, x0), x1]))
            for y in rows:
                if 0 <= y < H:
                    out[y, max(x0, 0):min(x1 + 1, W)] = (255, 128, 0)
            for x in cols:
                if 0 <= x < W:
                    out[max(y0, 0):min(y1 + 1, H), x] = (255, 128, 0)

    # ---- 跑马灯（disp_cnt 驱动，与目标包无关） ----
    mar_off = (disp_cnt & 0xFF) << 1
    mar_msg = 'ANLOGIC PH1P35 FPGA VISION PTZ TRACKER 2026                    '
    glyph_cache = {}
    for y in range(TXT3_Y0, min(TXT3_Y0 + 16, H)):
        row = y - TXT3_Y0
        for x in range(TXT_X0, W):
            pos = (x - TXT_X0 + mar_off) & 0xFFF
            # 外脑评审修复同步: 原实现 (pos>>3)&63 %63 在 pos>=512 后字符
            # 索引截断错位（与旧 RTL 同错）；正确公式 (pos>>3) % 63
            ci = (pos >> 3) % 63
            ch = mar_msg[ci]
            if ch == ' ':
                continue
            if ch not in glyph_cache:
                glyph_cache[ch] = glyph_bits(ch)
            if glyph_cache[ch][row][pos & 7]:
                out[y, x] = (0, 255, 255)
    return out


def gen_tb_osd():
    """OSD TB v2：3 帧（f0 空状态 / f1 换装后 / f2 连续帧），包在 f0 中帧注入。
    金标准 3 份（mar_off 随 disp_cnt 2/4/6 递增），验证双缓冲消撕裂 + 整帧一致。"""
    d = os.path.join(sp('step4_osd_integration'), 'sim')
    img = scene_red_square(560, 300, 90, noise=800)
    mask, sm, r = full_detect(img)
    state = {'valid': r['valid'], 'cx': r['cx'], 'cy': r['cy'],
             'min_x': r['min_x'], 'max_x': r['max_x'],
             'min_y': r['min_y'], 'max_y': r['max_y'],
             # lat=1：注入帧 fid=0、首显示帧 disp_cnt=1 -> 延迟 1 帧；
             # 真实链路稳态同样为 1（第 N 帧结果在第 N+1 帧显示）
             'lat': 1, 'preset': 0, 'algo': 0, 'mcnt': 64,
             # 运动框覆盖（外脑评审补：原 mot=None，运动框从未被像素级测试）：
             # 运动框 (200,200)-(260,240) 与目标框 (~560..649, 301..390) 明显不同，
             # 若 RTL 误用目标框坐标画运动框，逐像素对比必然失败
             'mot': {'valid': 1, 'cnt': 64,
                     'min_x': 200, 'max_x': 260,
                     'min_y': 200, 'max_y': 240},
             'bright': 0, 'contrast': 64}
    w(os.path.join(d, 'osd_base.hex'),
      [f"{p[0]:02X}{p[1]:02X}{p[2]:02X}" for p in img.reshape(-1, 3)])
    for f, dc in ((0, 1), (1, 2), (2, 3)):
        st = None if f == 0 else state
        out = render_osd(img, st, dc)
        w(os.path.join(d, f'osd_exp_f{f}.hex'),
          [f"{p[0]:02X}{p[1]:02X}{p[2]:02X}" for p in out.reshape(-1, 3)])
    with open(os.path.join(d, 'osd_coord.txt'), 'w') as fh:
        fh.write(f"{r['valid']:X}{r['cx']:03X}{r['cy']:03X}{r['min_x']:03X}"
                 f"{r['max_x']:03X}{r['min_y']:03X}{r['max_y']:03X}\n")
    return r


def gen_tb_motion():
    """帧差运动检测 TB（64x48 x 6 帧）：静止→出现→移动→消失→亚门限→末像素边界。
    期望值由 golden_model.frame_diff_motion 位精确生成。"""
    from golden_model import frame_diff_motion
    d = os.path.join(sp('step5_expansion'), 'sim')
    W, H, TH = 64, 48, 12
    m = np.zeros((H, W), dtype=np.uint8)
    frames = [m.copy()]                                       # f0 静止背景（只填缓存）
    m[10:18, 10:18] = 1; frames.append(m.copy())              # f1 出现 8x8 块
    m = np.zeros((H, W), dtype=np.uint8); m[20:28, 30:38] = 1
    frames.append(m.copy())                                   # f2 移动（旧位消失+新位出现）
    m = np.zeros((H, W), dtype=np.uint8); frames.append(m.copy())  # f3 消失
    m = np.zeros((H, W), dtype=np.uint8)
    for yy, xx in ((5, 5), (40, 50), (30, 20), (10, 60), (44, 3)):
        m[yy, xx] = 1
    frames.append(m.copy())                                   # f4 5px 亚门限（valid=0）
    # f5 末像素边界（外脑评审新增）：仅 (W-1,H-1) 一个差分像素。
    # 用于回归"帧末锁存漏末像素"缺陷（v3.1 已修：锁存延迟一拍）。
    m = np.zeros((H, W), dtype=np.uint8); m[H-1, W-1] = 1
    frames.append(m.copy())
    lines_in = []
    exp = []
    res = frame_diff_motion(frames, TH)
    for f, mm in enumerate(frames):
        lines_in += [f"{int(v)}" for v in mm.ravel()]
        r = res[f]
        if r is None:                     # 首帧无输出 → 期望全 0
            exp.append("000000000000000")
            continue
        packed = (r['cnt'] << 43) | (r['valid'] << 42) | (r['min_x'] << 31) \
                 | (r['max_x'] << 20) | (r['min_y'] << 10) | r['max_y']
        exp.append(f"{packed:015X}")
    w(os.path.join(d, 'motion_in.hex'), lines_in)
    w(os.path.join(d, 'motion_exp.txt'), exp)
    with open(os.path.join(d, 'motion_geo.txt'), 'w') as fh:
        fh.write(f"{W} {H} {TH} {len(frames)}" + chr(10))


def gen_all():
    print("== 生成 HSV 倒数 LUT RTL ==")
    gen_inv_lut()
    print("== 生成 8x16 字库 RTL ==")
    gen_font()
    print("== TB 向量 ==")
    gen_tb_rgb2hsv()
    gen_tb_threshold()
    gen_tb_smooth()
    gen_tb_centroid()
    gen_tb_chain()
    gen_tb_gimbal()
    gen_tb_osd()
    gen_tb_tpg()
    gen_tb_motion()
    print("全部向量生成完成")


if __name__ == '__main__':
    gen_all()
