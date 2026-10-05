# -*- coding: utf-8 -*-
"""bin_smooth3x3.v v6 的严格周期精确转录，与金标准对拍。"""
import numpy as np
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from golden_model import smooth3x3_majority

W, H = 64, 48

def rtl_model(flat_in, total):
    x = 0; y = 0
    a_msk = 0
    started = 0
    t0 = t1 = m0 = m1 = b0 = b1 = 0
    line0 = [0]*W; line1 = [0]*W
    outs = []
    for g in range(total):
        i_mask = flat_in[g]
        i_sof = 1 if g % (W*H) == 0 else 0
        i_eol = 1 if (g % W == W-1) else 0
        # 站B（寄存相位 = 令牌 g-1）
        if y == 0:
            t_sel = m_sel = b_sel = i_mask
        elif y == 1:
            t_sel = m_sel = line0[0]; b_sel = i_mask
        else:
            t_sel = line1[0]; m_sel = line0[0]; b_sel = i_mask
        win_main = t1 + t0 + t_sel + m1 + m0 + m_sel + b1 + b0 + b_sel
        win_last = t0 + 2*t_sel + m0 + 2*m_sel + b1 + 2*b0
        main_en = 1 if x >= 1 else 0
        last_en = 1 if (x == 0 and started) else 0
        if 12 <= g <= 15:
            print(f"g={g} x={x} y={y} t1={t1} t0={t0} tsel={t_sel} "
                  f"wm={win_main} main={main_en} om={om} im={i_mask}")
        om = 1 if (main_en and win_main >= 5) else (1 if (last_en and win_last >= 5) else 0)
        outs.append(om)
        # 寄存更新
        t1, t0 = t0, t_sel
        m1, m0 = m0, m_sel
        b1, b0 = b0, b_sel
        if x == 0:
            t1, m1, b1 = t_sel, m_sel, b_sel
        d0_old = line0[0]
        line0 = [a_msk] + line0[:W-1]
        line1 = [d0_old] + line1[:W-1]
        a_msk = i_mask
        if i_sof:
            x = 1; y = 0; started = 1
        elif i_eol:
            x = 0; y = 0 if y == H-1 else y + 1
        else:
            x += 1
    return outs

if __name__ == '__main__':
    d = '../03_vision/step2_color_centroid/03_project/sim'
    fin = np.loadtxt(d+'/smooth_in.hex', dtype=int).tolist()
    fex = np.loadtxt(d+'/smooth_exp.hex', dtype=int)
    total = W*H*4
    outs = rtl_model(fin[:total], total)
    nmis = 0
    for i, om in enumerate(outs):
        if om != fex[i]:
            if nmis < 6:
                y, x = divmod(i, W)
                print(f"MISM out{i} (r{y} c{x}) model={om} exp={fex[i]}")
            nmis += 1
    print(f"总输出 {len(outs)}（期望 {total}），失配 {nmis}")
