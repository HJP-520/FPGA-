# -*- coding: utf-8 -*-
"""
gen_raw10_sensor.py —— 虚拟 SC500CS RAW10 传感器（嵌入式集成仿真用）
生成 BGGR Bayer 场景（灰底 + 红块），打包为 isp_top 输入格式：
  40bit/拍 = 4 像素 × RAW10，P0=[39:30] P1=[29:20] P2=[19:10] P3=[9:0]
  每行 320 拍，tuser=帧首拍，tlast=行尾拍（与官方 raw10_unpacket_2lane 输出对流对接）
输出：04_embedded/03_project/sim/{raw10_beats.hex, raw10_meta.txt}
"""
import os
import numpy as np

W, H = 1280, 720
BOX = (500, 300, 80, 80)          # x0,y0,w,h —— 与 tb_vision_top 的 TPG 块相近
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, '04_embedded', '03_project', 'sim')

def gen():
    os.makedirs(OUT, exist_ok=True)
    # 10bit 灰底；BGGR：偶行 B G B G...，奇行 G R G R...
    raw = np.full((H, W), 512, dtype=np.int32)
    x0, y0, w, h = BOX
    # 红块：R 位点=900，G/B 位点=64（R 位点 = 奇行奇列）
    ys, xs = np.mgrid[y0:y0+h, x0:x0+w]
    # 红块: 对角棋盘布 R=900(与厂商 demosaic 的 Bayer 相位约定对齐,
    # 实测定稿——标准 BGGR 单相位会在插值后出现隔行绿纹)
    # R 位点=偶行偶列：与厂商 demosaic 的**实测**相位对齐（2026-10-03 定稿）。
    # 注：标准命名下 BGGR 的 R 应在奇行奇列；厂商链路对行/列相位有一格偏移，
    # 以实测定稿为准——红块经该链路渲染为红色即为验证（见板级使用指导第 5 节）。
    r_sites = ((ys & 1) == 0) & ((xs & 1) == 0)
    region_r = np.where(r_sites, 900, 64)
    raw[y0:y0+h, x0:x0+w] = region_r
    # 少量确定性噪声（LFSR 风格，可复现）
    rng = np.random.default_rng(500)
    noise_mask = rng.random((H, W)) < 0.002
    raw[noise_mask] = rng.integers(100, 900, int(noise_mask.sum()))

    # 打包：每 4 像素一拍
    flat = raw.ravel()
    beats, metas = [], []
    n = W * H
    beats_per_line = W // 4
    for i in range(0, n, 4):
        # 必须先转 Python int 再移位：numpy int32 左移 30 位会溢出
        # （背景拍高 10bit 被截断、噪声拍变负数，readmemh 遇 '-' 终止加载全 X）
        p0, p1, p2, p3 = int(flat[i]), int(flat[i+1]), int(flat[i+2]), int(flat[i+3])
        val = (p0 << 30) | (p1 << 20) | (p2 << 10) | p3
        beats.append(f"{val:010X}")
        beat_in_line = (i // 4) % beats_per_line
        sof = 1 if i == 0 else 0
        eol = 1 if beat_in_line == beats_per_line - 1 else 0
        metas.append(f"{(sof << 1) | eol:X}")   # 单字符（2bit 向量限 1 位数字）
    FRAMES = 4    # 集成仿真需连续 4 帧
    with open(os.path.join(OUT, 'raw10_beats.hex'), 'w') as f:
        f.write('\n'.join(beats * FRAMES) + '\n')
    with open(os.path.join(OUT, 'raw10_meta.txt'), 'w') as f:
        f.write('\n'.join(metas * FRAMES) + '\n')
    # 期望检测框（R 位点上取值后经 demosaic/AWB 的框位置不变）
    with open(os.path.join(OUT, 'raw10_expect.txt'), 'w') as f:
        f.write(f"{x0} {y0} {x0+w-1} {y0+h-1} {x0+w//2} {y0+h//2}\n")
    print(f"RAW10 虚拟传感器：{len(beats)} 拍，块 {BOX}，输出 {OUT}")

if __name__ == '__main__':
    gen()
