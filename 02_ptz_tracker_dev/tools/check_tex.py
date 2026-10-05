# -*- coding: utf-8 -*-
"""check_tex.py —— 教程 tex 的转义/字符静态检查（Step2 系列踩坑的集大成）

用法：python tools/check_tex.py docs/step3_tutorial.tex docs/step3_impl.tex ...

检查项：
  A. 正文裸特殊字符：^ ~ （排除注释行、Verbatim/Verilog、数学环境、\命令参数）
  B. \code{...}/\texttt{...} 内：裸 _ &、^、数学宏（\times 等）、未转义 $
  C. 反斜杠+全角标点（\： 等）
  D. Consolas/SimHei 缺字字符：✓ ∈ ⚠ ①..⑩ ️（出现在任何位置都提示）
匹配删除时保留换行，行号与源文件一致。
"""
import io, re, sys

MISSING_GLYPHS = '✓∈⚠️①②③④⑤⑥⑦⑧⑨⑩'
MATH_MACROS = ['\\times', '\\Sigma', '\\approx', '\\geq', '\\leq', '\\cdot',
               '\\pm', '\\max', '\\min', '\\rightarrow', '\\lfloor', '\\rfloor']


def blank(m):
    return re.sub(r'[^\n]', '', m.group(0))


def strip_envs(s):
    s = re.sub(r'\\begin\{(Verbatim|Verilog|tabular|tabbing)\}.*?\\end\{\1\}',
               blank, s, flags=re.S)
    s = re.sub(r'\$\$.*?\$\$|\$[^$\n]*\$', blank, s, flags=re.S)
    return s


def check(path):
    s = io.open(path, encoding='utf-8').read()
    print('===', path)
    n_issue = 0
    body = strip_envs(s)
    # A0. 正文裸下划线（排除 \code/\texttt 参数与 \_、注释行、\begin{tabular} 列格式）
    body_nc = re.sub(r'\\(?:code|texttt)\{(?:[^{}]|\{[^{}]*\})*\}',
                     blank, body, flags=re.S)
    body_nc = re.sub(r'\\(?:input|include|label|ref|usepackage|documentclass|newtcolorbox|definecolor|titleformat|titlespacing)\{[^}]*\}',
                     blank, body_nc, flags=re.S)
    for i, l in enumerate(body_nc.split('\n'), 1):
        code_line = l.split('%', 1)[0] if l.lstrip().startswith('%') else l
        # 去掉 \_ 转义后再找裸 _
        if re.search(r'(?<!\\)_', re.sub(r'\\_', '', code_line)):
            print(f'  A0 line {i}: bare _ | {l.strip()[:90]}')
            n_issue += 1
    # A. 正文裸 ^ ~（排除 \^{} \~{} 与注释行）
    for i, l in enumerate(body.split('\n'), 1):
        code_line = l.split('%', 1)[0] if l.lstrip().startswith('%') else l
        if re.search(r'(?<!\\)\^', code_line):
            print(f'  A line {i}: bare ^ | {l.strip()[:90]}')
            n_issue += 1
        if re.search(r'(?<![\\~])~(?!~)', code_line) and '\\~' not in code_line:
            print(f'  A line {i}: bare ~ | {l.strip()[:90]}')
            n_issue += 1
    # B. \code{...} 内容检查
    for m in re.finditer(r'\\(?:code|texttt)\{((?:[^{}]|\{[^{}]*\})*)\}', body):
        inner = m.group(1)
        line = body[:m.start()].count('\n') + 1
        probs = []
        if re.search(r'(?<!\\)_', inner):
            probs.append('bare _')
        if re.search(r'(?<!\\)&', inner):
            probs.append('bare &')
        if re.search(r'(?<!\\)\^', inner):
            probs.append('bare ^')
        if re.search(r'(?<!\\)\$', inner):
            probs.append('bare $')
        for b in MATH_MACROS:
            if b in inner:
                probs.append(b)
        if probs:
            print(f'  B line {line}: {probs} | {inner[:80]}')
            n_issue += 1
    # C. 反斜杠+全角标点
    for i, l in enumerate(s.split('\n'), 1):
        for m in re.finditer(r'\\[：；、。，（）“”‘’【】《》？！]', l):
            print(f'  C line {i}: {m.group(0)!r} | {l.strip()[:80]}')
            n_issue += 1
    # D. 缺字字符
    for i, l in enumerate(s.split('\n'), 1):
        hits = [c for c in MISSING_GLYPHS if c in l and c != '️']
        if '️' in l:
            hits.append('FE0F')
        if hits:
            print(f'  D line {i}: missing-glyph {hits} | {l.strip()[:80]}')
            n_issue += 1
    if n_issue == 0:
        print('  OK: no issues')
    return n_issue


if __name__ == '__main__':
    total = 0
    for p in sys.argv[1:] or []:
        total += check(p)
    sys.exit(1 if total else 0)
