from pathlib import Path
import numpy as np
from PIL import Image
T=Path(__file__).resolve().parent.parent
D=T/'sim/local_fixture';D.mkdir(exist_ok=True)
metrics={}
for w,h,fcount in [(256,96,12),(1280,720,3)]:
 y,x=np.indices((h,w)); bg=45+160*x/(w-1)+12*np.sin(y*2*np.pi/h)
 ink=((x%53==19)&(y%43>5)&(y%43<35))|((y%43==20)&(x%53>10)&(x%53<42))
 image=np.clip(np.rint(bg)-ink*24+((x*7+y*11)%5-2),0,255).astype(np.uint8)
 def spatial(a):
  tile=a.reshape(h//16,16,w//32,32).sum((1,3))//512
  lo=np.clip((np.arange(h)-8)//16,0,h//16-1);hi=np.minimum(lo+1,h//16-1)
  fy=np.where((np.arange(h)<8)|(np.arange(h)>=(h//16-1)*16+8),0,(np.arange(h)-8)%16)
  vy=(tile[lo]*(16-fy[:,None])+tile[hi]*fy[:,None]+8)//16
  lc=np.clip((np.arange(w)-16)//32,0,w//32-1);rc=np.minimum(lc+1,w//32-1)
  fx=np.where((np.arange(w)<16)|(np.arange(w)>=(w//32-1)*32+16),0,(np.arange(w)-16)%32)
  # At both clamped borders left and right caches select the same tile.
  rc=np.where((np.arange(w)<16)|(np.arange(w)>=(w//32-1)*32+16),lc,rc)
  m=(vy[:,lc]*(32-fx)+vy[:,rc]*fx+16)//32
  return vy,lc,rc,fx,m
 previous=None
 with (D/f'input_{w}.hex').open('w')as fi,(D/f'gold_{w}.hex').open('w')as fg,(D/f'map_{w}.hex').open('w')as fm:
  for f in range(fcount):
   a=np.clip(image.astype(int)+(20 if f in (3,4)else 0),0,255).astype(np.uint8)
   gray=f!=8;curve=0 if f in (8,11)else 2 if f==9 else 1 if f==10 else 3
   rows=8 if f==5 else h
   ready=previous is not None and gray
   if ready:vy,lc,rc,fx,m=spatial(previous)
   for yy in range(rows):
    for xx in range(0,w,4):
     vals=a[yy,xx:xx+4]
     rgb=''.join(f'{int(v):02x}'*3 for v in vals)
     # In non-gray test use distinct RGB channels to prove exact color bypass.
     if not gray:rgb=''.join(f'{int(v):02x}{int(v)^85:02x}{int(v)^170:02x}'for v in vals)
     fi.write(rgb+'\n')
     if ready:
      threshold=np.maximum(m[yy,xx:xx+4]-4,4)
      fg.write(''.join('ffffff'if int(v)>int(t)else'000000'for v,t in zip(vals,threshold))+'\n')
      fm.write(f'{(int(vy[yy,lc[xx]])<<13)|(int(vy[yy,rc[xx]])<<5)|int(fx[xx]):06x}\n')
     else:fg.write('0'*24+'\n');fm.write('000000\n')
   previous=a.copy()if rows==h and gray else None
 vy,lc,rc,fx,m=spatial(image);local=image>np.maximum(m-4,4);glob=image>image.mean()
 metrics[str(w)]={'local_dark_stroke_recall':float((~local)[ink].mean()),'global_dark_stroke_recall':float((~glob)[ink].mean()),'local_background_white':float(local[~ink].mean()),'global_background_white':float(glob[~ink].mean())}
 if w==1280:
  for name,a in [('original',image),('local',local.astype(np.uint8)*255),('global',glob.astype(np.uint8)*255)]:Image.fromarray(a).save(T/'assets'/f'binary_detail_{name}.png')
import json
(D/'metrics.json').write_text(json.dumps(metrics,indent=2))
print(metrics)
