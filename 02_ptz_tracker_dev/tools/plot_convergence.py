# -*- coding: utf-8 -*-
"""
plot_convergence.py —— 把 tb_closed_loop 的 closed_loop_trace.txt 画成收敛曲线（答辩素材）
用法：
    python plot_convergence.py                    # 默认路径
    python plot_convergence.py <trace.txt> [out.png]
列格式（来自 tb_closed_loop.v 第 60 行）：
    frame duty_x[us] err[px] theta[deg]
"""
import os
import sys

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_TRACE = os.path.join(ROOT, '03_vision', 'step4_osd_integration',
                             '03_project', 'sim', 'closed_loop_trace.txt')
DEFAULT_OUT = os.path.join(ROOT, '07_答辩素材', '闭环收敛曲线.png')

# 与 gimbal_ctrl.v / tb_closed_loop.v 一致的物理量
SERVO_MIN_US, SERVO_MAX_US = 700, 2300
SERVO_NEUTRAL_US = 1500          # 1500us = 回中
DZ_X = 20                        # 死区像素（tb_closed_loop 参数）
US_PER_DEG = 1.0 / 0.18          # 0.18 °/us -> 5.56 us/°
SETTLE_HINT = 36                 # TB 判定的锁定帧（TB_RESULT: settle_frame=36）


def load(path):
    data = np.loadtxt(path)
    if data.ndim == 1:
        data = data[None, :]
    return data[:, 0], data[:, 1], data[:, 2], data[:, 3]


def main():
    trace = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_TRACE
    out = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_OUT
    frame, duty_x, err, theta = load(trace)

    # 锁定判定：与 TB 相同口径——|err|<=DZ 连续 5 帧
    in_dz = np.abs(err) <= DZ_X
    settle = None
    run = 0
    for i, ok in enumerate(in_dz):
        run = run + 1 if ok else 0
        if run >= 5:
            settle = i - 4
            break

    plt.rcParams['font.sans-serif'] = ['Microsoft YaHei', 'SimHei', 'Arial']
    plt.rcParams['axes.unicode_minus'] = False
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(8.5, 6.2), sharex=True,
                                   gridspec_kw={'height_ratios': [3, 2]})
    fig.subplots_adjust(hspace=0.08, left=0.11, right=0.97, top=0.90, bottom=0.10)

    # 上图：云台脉宽与角度
    ax1.axhspan(SERVO_MIN_US, SERVO_MAX_US, color='#8ecae6', alpha=0.25, lw=0,
                label='舵机限幅区间 [%d, %d] µs' % (SERVO_MIN_US, SERVO_MAX_US))
    ax1.axhline(SERVO_NEUTRAL_US, color='gray', lw=0.8, ls=':', label='回中 1500 µs')
    ax1.plot(frame, duty_x, '-', color='#d62828', lw=1.8, label='duty_x（控制输出）')
    if settle is not None:
        ax1.axvline(settle, color='#2a9d8f', lw=1.2, ls='--',
                    label='锁定判定（第 %d 帧，|err|≤%d 连续 5 帧）' % (settle, DZ_X))
    ax1.set_ylabel('PWM 脉宽 (µs)')
    ax1.set_ylim(600, 2400)
    ax1.grid(alpha=0.3)
    ax1.legend(loc='lower right', fontsize=8.5, framealpha=0.9)
    ax1.set_title('闭环跟踪收敛过程（相机-舵机在环仿真，720p）', fontsize=12)

    # 下图：像素误差与云台角度
    ax2.plot(frame, err, '-o', color='#457b9d', ms=3, lw=1.5, label='指向误差 err_x (px)')
    ax2.axhspan(-DZ_X, DZ_X, color='#2a9d8f', alpha=0.18, lw=0,
                label='死区 ±%d px' % DZ_X)
    ax2.axhline(0, color='gray', lw=0.8)
    ax2.set_ylabel('误差 (px)')
    ax2.set_xlabel('帧号')
    ax2.grid(alpha=0.3)
    ax2.legend(loc='upper right', fontsize=8.5, framealpha=0.9)

    if settle is not None:
        err_final = int(abs(err[-1]))
        fig.text(0.97, 0.015,
                 '锁定帧：%s   末帧 |err|=%d px   帧数=%d' %
                 (settle if settle is not None else '未锁定', err_final, len(frame)),
                 ha='right', fontsize=8.5, color='#444444')

    os.makedirs(os.path.dirname(out), exist_ok=True)
    fig.savefig(out, dpi=200)
    print('已保存:', out)
    print('锁定帧:', settle, ' 末帧|err|:', int(abs(err[-1])), 'px, 总帧数:', len(frame))


if __name__ == '__main__':
    main()
