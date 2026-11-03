from pathlib import Path
import json
from PIL import Image,ImageFont,ImageDraw
T=Path(__file__).resolve().parent.parent;H=T/'user_source/hdl_source'
rows=json.loads((T/'_build/v9_font_rows.json').read_text())
font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',60)
for g,ch in enumerate('二值化',93):
 im=Image.new('L',(64,96));d=ImageDraw.Draw(im);b=d.textbbox((0,0),ch,font=font)
 d.text(((64-b[2]+b[0])//2-b[0],(96-b[3]+b[1])//2-b[1]),ch,font=font,fill=255)
 im=im.resize((16,24),Image.Resampling.LANCZOS)
 for y in range(3,23):rows[g*32+y]=sum(min(3,(im.getpixel((x,y))*3+127)//255)<<(x*2)for x in range(16))
(H/'ui_font.dath').write_text(''.join(f'{v:08x}\n'for v in rows))
exec((T/'tools/compact_font.py').read_text(),{'__file__':str(T/'tools/compact_font.py')})
