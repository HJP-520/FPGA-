# -*- coding: utf-8 -*-
"""把 case 版 marquee_rom_64.v 机械转换为数组 ROM（位值不变）。
用法：python gen_marquee_rom.py <case版.v>   （输出到同目录）
历史：2026-10-03 为修复 74.25MHz 跑马灯关键路径而转换（迭代记录 #N+7）。"""
import io, re, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
pairs = re.findall(r"10'h([0-9A-Fa-f]{3}):\s*O_bits\s*=\s*8'h([0-9A-Fa-f]{2});", src)
L = ['// 自动生成：tools/gen_marquee_rom.py（由 case 版逐值转数组 ROM）',
     'module marquee_rom_64 (', '    input  wire [9:0]  I_addr,',
     '    output wire [7:0]  O_bits', ');', '',
     '    (* rom_style = "distributed" *) reg [7:0] mem [0:1023];', '',
     '    initial begin']
for a, b in pairs:
    L.append("        mem[10'h%s] = 8'h%s;" % (a.upper(), b.upper()))
L += ['    end', '', '    assign O_bits = mem[I_addr];', '', 'endmodule']
io.open(sys.argv[1], 'w', encoding='utf-8').write('
'.join(L) + '
')
print('converted', len(pairs), 'entries')
