# -*- coding: utf-8 -*-
"""把 PDF 每页渲染为 PNG，供视觉验收。"""
import os, sys
import pymupdf

pdf = sys.argv[1] if len(sys.argv) > 1 else 'D:/fpga-ptz-tracker/docs/step2_tutorial.pdf'
outdir = sys.argv[2] if len(sys.argv) > 2 else 'D:/fpga-ptz-tracker/docs/_render'
os.makedirs(outdir, exist_ok=True)
doc = pymupdf.open(pdf)
for i, page in enumerate(doc, 1):
    pix = page.get_pixmap(dpi=110)
    p = os.path.join(outdir, f'p{i:02d}.png')
    pix.save(p)
print('pages:', len(doc), '->', outdir)
