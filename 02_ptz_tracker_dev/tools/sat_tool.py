#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""sat_tool.py —— 饱和度增强工具（预览 / RTL 位精确校验）

公式（与 RTL axis_saturation_rgb96.v 严格一致，全整数）：
    Y   = (77*R + 150*G + 29*B) >> 8          # BT.601, 8bit
    d   = c - Y                               # 有符号
    t   = (K_Q4 * d + 8) >> 4                 # K_Q4: Q4.4, 16=1.00x, 21≈1.31x
    out = clamp(Y + t, 0, 255)

子命令：
  sweep  —— 对一帧 hex 做多档 K 预览拼图（+可选实拍照片示意）
  check  —— 校验 RTL 仿真输出帧与 Python 参考是否逐字节一致

用法：
  python sat_tool.py sweep --frame passthrough_frame_0.hex --out sat_sweep_sim.png \
      --photo D:/QQ/IMG_20261004_171700.jpg --photo-out sat_sweep_photo.png
  python sat_tool.py check --before baseline.hex --after new.hex --k 21
"""
import argparse
import sys

W, H = 1280, 720


def sat_pixel(r, g, b, k_q4):
    y = (77 * r + 150 * g + 29 * b) >> 8
    out = []
    for c in (r, g, b):
        v = y + ((k_q4 * (c - y) + 8) >> 4)
        out.append(0 if v < 0 else (255 if v > 255 else v))
    return out[0], out[1], out[2]


def load_hex(path):
    px = []
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            v = int(line, 16)
            px.append(((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF))
    if len(px) != W * H:
        print(f"[warn] {path}: {len(px)} pixels != {W*H}")
    return px


def apply_k(px, k_q4):
    tv = (16 * 77) | (16 * 150) | (16 * 29)  # unused, keep lint quiet
    return [sat_pixel(r, g, b, k_q4) for (r, g, b) in px]


# ---------------- sweep ----------------

def cmd_sweep(args):
    from PIL import Image, ImageDraw, ImageFont

    def font(size, bold=False):
        for p in (r"C:\Windows\Fonts\msyhbd.ttc" if bold else r"C:\Windows\Fonts\msyh.ttc",
                  r"C:\Windows\Fonts\arialbd.ttf" if bold else r"C:\Windows\Fonts\arial.ttf"):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
        return ImageFont.load_default()

    ks = [16, 21, 28, 32]
    labels = ["original (K=16, x1.00)", "K=21 (x1.31)", "K=28 (x1.75)", "K=32 (x2.00)"]

    px = load_hex(args.frame)
    im0 = Image.new("RGB", (W, H))
    im0.putdata(px)

    # 以红方块为中心裁一块，放大看差异
    box = (400, 225, 880, 495)  # 480x270
    panels = [im0.crop(box)]
    for k in ks[1:]:
        tmp = Image.new("RGB", (W, H))
        tmp.putdata(apply_k(px, k))
        panels.append(tmp.crop(box))

    pw, ph = panels[0].size
    scale = 2
    f = font(20, bold=True)
    lab_h = 34
    canvas = Image.new("RGB", (pw * 2 * scale + 30, (ph * scale + lab_h) * 2 + 30), (24, 24, 24))
    d = ImageDraw.Draw(canvas)
    for i, (p, lab) in enumerate(zip(panels, labels)):
        p = p.resize((pw * scale, ph * scale), Image.NEAREST)
        col, row = i % 2, i // 2
        x = 10 + col * (pw * scale + 10)
        y = 10 + row * (ph * scale + lab_h + 10)
        canvas.paste(p, (x, y + lab_h))
        d.text((x + 6, y + 4), lab, fill=(240, 240, 240), font=f)
    canvas.save(args.out)
    print(f"[ok] 仿真帧对比图 -> {args.out}")

    if args.photo:
        ph_im = Image.open(args.photo).convert("RGB")
        w0, h0 = ph_im.size
        # 取中下部桌面区域（有彩色物体的地方）做横构图
        band = ph_im.crop((0, int(h0 * 0.50), w0, int(h0 * 0.95)))
        band = band.resize((760, int(band.height * 760 / band.width)))
        pv = [band] + [None] * 3
        # 用像素级变换（缩略图尺寸，速度OK）
        for idx, k in enumerate(ks[1:], start=1):
            tmp = band.copy()
            data = [sat_pixel(r, g, b, k) for (r, g, b) in list(tmp.getdata())]
            tmp.putdata(data)
            pv[idx] = tmp
        bw, bh = band.size
        c2 = Image.new("RGB", (bw * 2 + 30, (bh + lab_h) * 2 + 30), (24, 24, 24))
        d2 = ImageDraw.Draw(c2)
        for i, (p, lab) in enumerate(zip(pv, labels)):
            col, row = i % 2, i // 2
            x = 10 + col * (bw + 10)
            y = 10 + row * (bh + lab_h + 10)
            c2.paste(p, (x, y + lab_h))
            d2.text((x + 6, y + 4), lab + "  [实拍照片示意]", fill=(240, 240, 240), font=font(20, True))
        c2.save(args.photo_out)
        print(f"[ok] 实拍照片示意 -> {args.photo_out}")


# ---------------- check ----------------

def cmd_check(args):
    before = load_hex(args.before)
    after = load_hex(args.after)
    if len(before) != W * H or len(after) != W * H:
        # check 模式严格：任一侧非 1280x720 直接 FAIL（sweep 允许 warn）
        print(f"[FAIL] 帧尺寸非 {W}x{H}: before={len(before)} after={len(after)}")
        sys.exit(1)
    bad = 0
    first = None
    for i, ((r, g, b), (R, G, B)) in enumerate(zip(before, after)):
        e = sat_pixel(r, g, b, args.k)
        if (R, G, B) != e:
            bad += 1
            if first is None:
                first = (i, (r, g, b), (R, G, B), e)
    n = len(before)
    if bad == 0:
        print(f"[PASS] {n} 像素全部与 Python 参考一致 (K_Q4={args.k})")
    else:
        y, x = first[0] // W, first[0] % W
        print(f"[FAIL] {bad}/{n} 像素不一致; 首个: ({x},{y}) in={first[1]} rtl={first[2]} py={first[3]}")
        sys.exit(1)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("sweep")
    sp.add_argument("--frame", required=True)
    sp.add_argument("--out", required=True)
    sp.add_argument("--photo")
    sp.add_argument("--photo-out", default="sat_sweep_photo.png")
    sp.set_defaults(func=cmd_sweep)

    cp = sub.add_parser("check")
    cp.add_argument("--before", required=True)
    cp.add_argument("--after", required=True)
    cp.add_argument("--k", type=int, default=21)
    cp.set_defaults(func=cmd_check)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
