from pathlib import Path
from PIL import Image, ImageFont, ImageDraw

T=Path(__file__).resolve().parent.parent
P=T/'assets'
W,H=320,48
mask=Image.new('L',(W,H),0)
d=ImageDraw.Draw(mask)
latin=ImageFont.truetype('C:/Windows/Fonts/segoeuib.ttf',34)
han=ImageFont.truetype('C:/Windows/Fonts/msyhbd.ttc',32)
# Draw each run at native pixel size; no enlarged low-resolution glyphs.
left=4
for text,font,gap in [('SC520',latin,14),('视觉系统',han,0)]:
 box=d.textbbox((0,0),text,font=font)
 top=(H-(box[3]-box[1]))//2-box[1]
 d.text((left,top),text,font=font,fill=255)
 left+=round(d.textlength(text,font=font))+gap
assert left<W-2,left
from PIL import ImageFilter
outline=mask.filter(ImageFilter.MaxFilter(3))
levels=[]
for yy in range(H):
 for xx in range(W):
  a=mask.getpixel((xx,yy))
  levels.append(3 if a>=176 else 2 if a>=48 else 1 if outline.getpixel((xx,yy))>=48 else 0)
assert all(v==0 for i,v in enumerate(levels) if i%W>=256 or i//W<7 or i//W>40)
assert set(levels[7*W:8*W]+levels[40*W:41*W])<={0,1}
top=sum(1<<x for x in range(256) if levels[7*W+x])
bottom=sum(1<<x for x in range(256) if levels[40*W+x])
import re
hud=T/'user_source/hdl_source/ui_hud_v17_r1.v'
source=hud.read_text(encoding='utf-8')
source=re.sub(r"TOP_OUTLINE=256'h[0-9a-f]+",f"TOP_OUTLINE=256'h{top:064x}",source)
source=re.sub(r"BOTTOM_OUTLINE=256'h[0-9a-f]+",f"BOTTOM_OUTLINE=256'h{bottom:064x}",source)
hud.write_text(source,encoding='utf-8')
packed_levels=[levels[y*W+x] for y in range(8,40) for x in range(256)]
words=[]
for i in range(0,len(packed_levels),16):
 word=sum(v<<(2*j) for j,v in enumerate(packed_levels[i:i+16]))
 words.append(f'{word:08x}')
(T/'user_source/hdl_source/ui_title.hex').write_text('\n'.join(words)+'\n')
(P/'title_golden.hex').write_text('\n'.join(str(v) for v in levels)+'\n')
colors=[(46,54,66),(12,16,23),(155,170,188),(244,247,251)]
preview=Image.new('RGB',(W,H))
preview.putdata([colors[i] for i in levels])
out=P
preview.save(out/'SC520_title_preview.png')
preview.resize((W*3,H*3),Image.Resampling.NEAREST).save(out/'SC520_title_pixels_3x.png')
print('TITLE_ROM_READY',W,H,'native pixels;',len(words),'32-bit words')
