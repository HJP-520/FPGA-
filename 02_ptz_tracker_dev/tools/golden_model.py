# -*- coding: utf-8 -*-
"""
golden_model.py —— 视觉方向全链路位精确（bit-true）金标准模型
=================================================================
本文件是整个视觉软件包的"算术真值来源"：
  RTL（ModelSim 仿真）与上位机（Python）必须逐位一致。
任何对算术的修改必须先改这里，再同步 RTL，并在迭代报告中记录。

定点算术约定（与 RTL 严格一一对应，见 02_技术文档）：
  1) RGB->HSV：
     max = max(R,G,B), min = min(R,G,B), delta = max-min
     V = max            (8bit)
     S = delta          (8bit, 未归一化饱和度代理，省一个除法器)
     inv[d] = floor(3840/d)                (12bit 查找表, d=1..255)
     3扇区优先级 R > G > B（同 max 时取先者）：
       R 最大: h = clamp(((G-B)*inv[d]) >>> 6, 0, 60), H = 0  + h
       G 最大: h = clamp(((B-R)*inv[d]) >>> 6, 0, 60), H = 120+ h
       B 最大: h = clamp(((R-G)*inv[d]) >>> 6, 0, 60), H = 240+ h
     delta==0 时 H=0（消色差）。
     >>> 为算术右移（floor），Verilog 中对 signed 用 >>>。
     已知限制：H 只能落在 {0..60,120..180,240..300} 三个扇区，
     品红/青/黄绿等中间色调会被并入相邻扇区（详见方案对比报告）。
  2) 阈值分割（掩码 mask=1 表示目标像素）：
     mask = H在[h_lo..h_hi]（支持环绕） 且 S>=s_lo 且 v_lo<=V<=v_hi
  3) 3x3 二值平滑（多数表决）：
     sum(3x3窗内mask) >= 5 -> 1
     边界策略：行/列复制（replicate）；
     y==0: 上两行均取当前行; y==1: line1(顶)取 row0（RTL 中
     顶行缓存在 y==1 时视为无效，用 row0 顶替）——与 RTL 逐拍对应。
  4) 质心/包围框（对平滑后的 mask）：
     count=Σmask, sum_x=Σx·mask, sum_y=Σy·mask
     count >= MIN_PIXELS 才有效: cx = floor(sum_x/count), cy = floor(sum_y/count)
     bbox = 平滑后 mask 的 min/max x/y（无目标时全 0 且 valid=0）
  5) 云台控制（gimbal_ctrl，Q8.8 定点乘）：
     err = invert ? (center-target) : (target-center)
     kp_term = (err * KP) >>> 8（有符号算术右移）
     |err|<=DZ 时 kp_term=0；限幅 [SERVO_MIN_US, SERVO_MAX_US]；
     单帧限速 SLEW_US；丢失目标保持原脉宽并累加 lost_cnt。
"""

import numpy as np

# ---------------- 全局几何参数（与 RTL 参数默认值一致） ----------------
IMG_W = 1280
IMG_H = 720
CENTER_X = IMG_W // 2      # 640
CENTER_Y = IMG_H // 2      # 360
MIN_PIXELS = 30            # 质心有效性像素门限

# HSV 预置阈值组（8 组，与 hsv_threshold.v 中 PRESETS 完全一致）
# 每组: (h_lo, h_hi, s_lo, v_lo, v_hi)
HSV_PRESETS = [
    (335, 25,  80, 60, 255),   # 0: 红色（环绕窗口）
    (110, 145, 60, 40, 255),   # 1: 绿色
    (200, 250, 60, 40, 255),   # 2: 蓝色
    (20,  70,  80, 80, 255),   # 3: 橙黄
    (170, 195, 60, 60, 255),   # 4: 青
    (300, 330, 60, 40, 255),   # 5: 品红
    (0,   359, 10, 220, 255),  # 6: 白色（低饱和高亮度）
    (0,   359, 0,  0,   60),   # 7: 黑色（低亮度）
]


def build_inv_lut():
    """inv[d] = floor(3840/d)，与 rtl/hsv_inv_lut.v（自动生成）逐项一致。"""
    lut = np.zeros(256, dtype=np.int32)
    for d in range(1, 256):
        lut[d] = 3840 // d
    return lut


_INV = build_inv_lut()


def rgb_to_hsv(r, g, b):
    """向量化 RGB888 -> (H[0..359], S=delta, V=max)，逐位复刻 RTL 算术。"""
    r = np.asarray(r, dtype=np.int32)
    g = np.asarray(g, dtype=np.int32)
    b = np.asarray(b, dtype=np.int32)
    mx = np.maximum(np.maximum(r, g), b)
    mn = np.minimum(np.minimum(r, g), b)
    d = mx - mn
    v = mx
    s = d
    inv = np.where(d > 0, _INV[np.clip(d, 0, 255)], 0)

    # 3 扇区，优先级 R > G > B
    is_r = (r >= g) & (r >= b)
    is_g = (~is_r) & (g >= r) & (g >= b)
    is_b = ~(is_r | is_g)

    h_r = np.clip(((g - b) * inv) >> 6, 0, 60)      # >> 为 floor 算术移位
    h_g = np.clip(((b - r) * inv) >> 6, 0, 60)
    h_b = np.clip(((r - g) * inv) >> 6, 0, 60)

    h = np.where(is_r, h_r, np.where(is_g, 120 + h_g, 240 + h_b))
    h = np.where(d == 0, 0, h)
    return h.astype(np.int32), s.astype(np.int32), v.astype(np.int32)


def hsv_threshold(h, s, v, preset_idx):
    """HSV -> 二值掩码（支持 H 窗口环绕）。"""
    h_lo, h_hi, s_lo, v_lo, v_hi = HSV_PRESETS[preset_idx]
    if h_lo <= h_hi:
        in_h = (h >= h_lo) & (h <= h_hi)
    else:
        in_h = (h >= h_lo) | (h <= h_hi)
    return (in_h & (s >= s_lo) & (v >= v_lo) & (v <= v_hi)).astype(np.uint8)


def smooth3x3_majority(mask, w=IMG_W, hgt=IMG_H):
    """3x3 多数表决平滑，边界复制 + 前两行特殊处理，与 RTL 逐拍语义一致。"""
    m = mask.astype(np.int32)
    out = np.zeros_like(m)
    for y in range(hgt):
        row_top = m[y - 2] if y >= 2 else None
        row_mid = m[y - 1] if y >= 1 else None
        cur = m[y]
        if y == 0:
            top = mid = cur
        elif y == 1:
            top = mid = row_mid          # RTL: line1 无效，用 row0 顶替
        else:
            top, mid = row_top, row_mid
        ext = np.empty(w + 2, dtype=np.int32)
        for row, name in ((top, 't'), (mid, 'm'), (cur, 'b')):
            e = np.empty(w + 2, dtype=np.int32)
            e[1:w + 1] = row
            e[0] = row[0]
            e[w + 1] = row[w - 1]
            if name == 't':
                te = e
            elif name == 'm':
                me = e
            else:
                be = e
        s = (te[:-2] + te[1:-1] + te[2:] +
             me[:-2] + me[1:-1] + me[2:] +
             be[:-2] + be[1:-1] + be[2:])
        out[y] = (s >= 5).astype(np.uint8)
    return out


def centroid_bbox(mask_smooth, w=IMG_W, hgt=IMG_H, min_pixels=MIN_PIXELS):
    """平滑掩码 -> 质心 + 包围框 + 计数（floor 除法，除零保护）。"""
    ys, xs = np.nonzero(mask_smooth)
    cnt = int(xs.size)
    res = dict(count=cnt, valid=0, cx=0, cy=0,
               min_x=0, max_x=0, min_y=0, max_y=0)
    if cnt >= min_pixels:
        sx = int(xs.sum())
        sy = int(ys.sum())
        res.update(valid=1, cx=sx // cnt, cy=sy // cnt,
                   min_x=int(xs.min()), max_x=int(xs.max()),
                   min_y=int(ys.min()), max_y=int(ys.max()))
    return res


def gimbal_ctrl_step(err, duty_prev, kp_q8, kd_q8=0, err_prev=0,
                     deadzone=25, slew=200, servo_min=700, servo_max=2300,
                     invert=False):
    """gimbal_ctrl.v 单轴单帧步进的位精确复刻。err 为有符号像素误差。"""
    if invert:
        err = -err
    if abs(err) <= deadzone:
        kp_term = 0
    else:
        kp_term = (err * kp_q8) >> 8          # Python >> 对负数即 floor
    kd_term = ((err - err_prev) * kd_q8) >> 8 if kd_q8 else 0
    step = kp_term + kd_term
    if step > slew:
        step = slew
    elif step < -slew:
        step = -slew
    duty = duty_prev + step
    if duty > servo_max:
        duty = servo_max
    elif duty < servo_min:
        duty = servo_min
    return duty


# ---------------- 帧差运动检测（motion_detect.v 的位精确复刻，v2） ----------------

def frame_diff_motion(frames, mot_th=12):
    """帧差运动检测：对应 motion_detect.v（2026-09-20 修正版）。

    位精确语义（与 RTL 严格一一对应）：
      - 第 0 帧只填充前帧缓存，无输出脉冲（prev_ready 门控）；
      - 每帧 sof 拍（(0,0) 像素）只写缓存、不参与比对；
      - 第 N>=1 帧：diff = cur ^ prev（除 (0,0) 全帧比对），
        输出 cnt 与 diff 像素包围框，valid = (cnt >= mot_th)；
        cnt==0 时 bbox 全 0。
    frames: [HxW 0/1 uint8] 时间顺序。
    返回 list：第 0 帧为 None，其余为 dict(cnt, valid, min_x, max_x, min_y, max_y)。
    """
    out = []
    prev = None
    for m in frames:
        if prev is None:
            out.append(None)
            prev = m.copy()
            continue
        d = (m.astype(np.int8) != prev.astype(np.int8))
        d[0, 0] = False                       # sof 拍存而不比
        ys, xs = np.nonzero(d)
        cnt = int(xs.size)
        if cnt:
            r = dict(cnt=cnt, valid=int(cnt >= mot_th),
                     min_x=int(xs.min()), max_x=int(xs.max()),
                     min_y=int(ys.min()), max_y=int(ys.max()))
        else:
            r = dict(cnt=0, valid=0, min_x=0, max_x=0, min_y=0, max_y=0)
        out.append(r)
        prev = m.copy()
    return out


# ---------------- 整链封装（图像 -> 掩码/质心/框） ----------------

def full_detect(rgb_img, preset_idx=0):
    """rgb_img: HxWx3 uint8。返回(掩码, 平滑掩码, 质心结果)。"""
    r = rgb_img[:, :, 0].ravel().astype(np.int32)
    g = rgb_img[:, :, 1].ravel().astype(np.int32)
    b = rgb_img[:, :, 2].ravel().astype(np.int32)
    h, s, v = rgb_to_hsv(r, g, b)
    mask = hsv_threshold(h, s, v, preset_idx).reshape(IMG_H, IMG_W)
    sm = smooth3x3_majority(mask)
    return mask, sm, centroid_bbox(sm)


if __name__ == '__main__':
    # 自检：三基色 + 消色差 + 位精确 LUT
    for rgb, exp_h in [((224, 32, 32), 0), ((32, 224, 32), 120),
                       ((32, 32, 224), 240), ((128, 128, 128), 0),
                       ((255, 255, 255), 0), ((0, 0, 0), 0)]:
        hh, ss, vv = rgb_to_hsv(*rgb)
        print(f"RGB{rgb} -> H={int(hh)} S={int(ss)} V={int(vv)} (期望H≈{exp_h})")
    print("inv[1..8] =", _INV[1:9].tolist())
    print("golden_model 自检完成")
