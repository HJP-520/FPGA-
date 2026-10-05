# -*- coding: utf-8 -*-
"""
dump2png.py —— 把 frame_dump24 转储的 hex 帧转成 PNG（肉眼看仿真画面）

用法：
  python tools/dump2png.py <仿真目录> <前缀> <帧号...> [--out <输出目录>]
示例：
  python tools/dump2png.py 08_board_bringup/01_video_passthrough/sim passthrough_frame 0 1 2 3

输入：<仿真目录>/<前缀>_<帧号>.hex（frame_dump24 格式：每行 6 位十六进制 RGB888）
输出：<输出目录>/<前缀>_<帧号>.png（默认输出到 <仿真目录>/../sim_out 或 sim_out）
"""
import os
import sys

import numpy as np
from PIL import Image

W, H = 1280, 720


def load_frame(path):
    px = np.zeros((H, W, 3), dtype=np.uint8)
    i = 0
    n_x = 0
    with open(path, 'r') as f:
        for line in f:
            line = line.strip()
            if len(line) < 6:
                continue
            try:
                v = int(line[:6], 16)
            except ValueError:
                n_x += 1          # 'xxxxxx' = X 传播（未初始化 RAM 读出）
                i += 1
                continue
            y, x = divmod(i, W)
            if y < H:
                px[y, x] = ((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF)
            i += 1
    if i != W * H:
        print(f'  提示: {path} 像素数 {i} != {W*H}（帧不完整也会尽量出图）')
    if n_x:
        print(f'  提示: {path} 含 {n_x} 个 X 像素（按黑画，多为未初始化 RAM 的帧首现象）')
    return px


def main():
    argv = sys.argv[1:]
    outdir = 'sim_out'
    if '--out' in argv:
        outdir = argv[argv.index('--out') + 1]
        argv = argv[:argv.index('--out')] + argv[argv.index('--out') + 2:]
    if len(argv) < 1:
        sys.exit(__doc__)
    simdir = argv[0]
    prefix = argv[1] if len(argv) > 1 else 'passthrough_frame'
    frames = [int(a) for a in argv[2:]] or [0]
    os.makedirs(outdir, exist_ok=True)
    for n in frames:
        p = os.path.join(simdir, f'{prefix}_{n}.hex')
        if not os.path.exists(p):
            print(f'跳过（不存在）: {p}')
            continue
        img = load_frame(p)
        out = os.path.join(outdir, f'{prefix}_{n}.png')
        Image.fromarray(img).save(out)
        mean = img.mean(axis=(0, 1))
        print(f'{out}  亮度均值 R={mean[0]:.1f} G={mean[1]:.1f} B={mean[2]:.1f}')


if __name__ == '__main__':
    main()
