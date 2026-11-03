from pathlib import Path
T=Path(__file__).resolve().parent.parent;H=T/'user_source/hdl_source'
rows=[int(s,16)for s in (H/'ui_font.dath').read_text().split()]
assert len(rows)==4096
assert all(v==0 for i,v in enumerate(rows)if i//32>=96 or not 3<=i%32<=22)
compact=[0]*2048
def font_index(g,r):return g*16+r-3 if r<=18 else 1536+g*4+r-19
for glyph in range(96):
 for row in range(3,23):compact[font_index(glyph,row)]=rows[glyph*32+row]
for address in range(4096):
 g,r=address//32,address%32
 result=compact[font_index(g,r)]if g<96 and 3<=r<=22 else 0
 assert result==rows[address]
(H/'ui_font_compact.dath').write_text(''.join(f'{r:08x}\n'for r in compact))
print('FONT_COMPACT_PROOF_PASS addresses=4096 words=4096->2048 latency=1')
