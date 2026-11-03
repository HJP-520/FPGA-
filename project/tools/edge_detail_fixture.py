from pathlib import Path
import numpy as np
import json
from PIL import Image,ImageDraw
T=Path(__file__).resolve().parent.parent;D=T/'sim/edge_detail_fixture';D.mkdir(exist_ok=True)
A=T/'assets/edge_detail_v16';A.mkdir(exist_ok=True)
TH=60
def masks(im):
 z=im.astype(np.int32);luma=(z[:,:,0]>>2)+(z[:,:,1]>>1)+(z[:,:,2]>>2)
 p=(luma[:,::2]+luma[:,1::2])//2
 a,b,c=p[:-2,:-2],p[:-2,1:-1],p[:-2,2:]
 d,e,f=p[1:-1,:-2],p[1:-1,1:-1],p[1:-1,2:]
 g,h,i=p[2:,:-2],p[2:,1:-1],p[2:,2:]
 dx=np.stack([c-a,f-d,i-g]);dy=np.stack([a-g,b-h,c-i])
 mag=np.abs(dx[0]+2*dx[1]+dx[2])+np.abs(dy[0]+2*dy[1]+dy[2])
 th=max(TH>>3,1)
 support=((dx>=th).sum(0)>=2)|((dx<=-th).sum(0)>=2)|((dy>=th).sum(0)>=2)|((dy<=-th).sum(0)>=2)
 old=(mag>=TH)&support
 robust=(np.abs(np.median(dx,axis=0))+np.abs(np.median(dy,axis=0)))*4>=TH
 hi=np.maximum.reduce([b,d,f,h]);lo=np.minimum.reduce([b,d,f,h]);r=(TH+3)//4
 ridge=(np.minimum.reduce([a,e,i])-hi>=r)|(lo-np.maximum.reduce([a,e,i])>=r)|(np.minimum.reduce([c,e,g])-hi>=r)|(lo-np.maximum.reduce([c,e,g])>=r)
 new=(old&robust)|ridge
 result=[]
 for m in [old,new]:
  out=np.zeros(p.shape,dtype=np.uint8);out[2:,1:-1]=m
  # Existing endpoint masks: first pair of every row, last pair at EOL.
  result.append(out)
 return result
def make(scene,W,H):
 y,x=np.indices((H,W));rng=np.random.default_rng(20261031+scene)
 if scene<3:
  v=np.clip(110+rng.normal(0,[6,10,14][scene],(H,W)),0,255).astype(np.uint8)
 elif scene==3:
  v=np.full((H,W),90,dtype=np.uint8);v[(x%24==12)&(y%16==8)]=250
 elif scene==4:v=np.where(x>=W//2,100,80).astype(np.uint8)
 elif scene==5:v=np.where(y>=H//2,100,80).astype(np.uint8)
 elif scene==6:v=np.where(x>=2*y,100,80).astype(np.uint8)
 elif scene==7:v=np.where((x==W//2)|(x==W//2+1),220,80).astype(np.uint8)
 elif scene==8:v=np.where(y==H//2,220,80).astype(np.uint8)
 elif scene==9:v=np.where((x==2*y)|(x==2*y+1),220,80).astype(np.uint8)
 elif scene==10:v=np.where((x-W//2)**2+(y-H//2)**2<(min(W,H)//3)**2,210,40).astype(np.uint8)
 elif scene==11:v=np.where((x>=W//2)&(y>=H//2),220,80).astype(np.uint8)
 else:
  v=np.clip(100+x*40//W+rng.normal(0,7,(H,W)),0,255).astype(np.uint8)
  v[(x>W//5)&(x<W//2)&(y>H//5)&(y<H*4//5)]=200
  v[(x-W*3//4)**2+(y-H//2)**2<(H//4)**2]=45
  v[(x==2*y+24)|(x==2*y+25)]=230
 im=np.repeat(v[:,:,None],3,axis=2)
 if scene==12:
  # Color detail at all four independent lanes must remain bit-exact off edges.
  im[:,:,1]=np.minimum(im[:,:,1].astype(np.uint16)+x%11,255).astype(np.uint8)
  im[:,:,2]=np.maximum(im[:,:,2].astype(np.int16)-y%9,0).astype(np.uint8)
 return im
def save(name,im):
 old,new=masks(im)
 words=im.reshape(-1,12)
 (D/f'{name}_input.hex').write_text(''.join(''.join(f'{int(c):02x}'for c in w)+'\n'for w in words))
 for label,m in [('old',old),('new',new)]:
  packed=m[:,::2]+2*m[:,1::2]
  (D/f'{name}_{label}.hex').write_text(''.join(f'{int(a):x}\n'for a in packed.flat))
 return old,new
names=['noise6','noise10','noise14','isolated','weak_vertical','weak_horizontal','weak_diagonal','thin_vertical','thin_horizontal','thin_diagonal','circle','corner','mixed']
metrics={'scope':'deterministic synthetic RGB scenes; edge-pair counts, not measured camera accuracy','threshold':TH,'small_image':[128,64],'scenes':{}}
for s,name in enumerate(names):
 im=make(s,128,64);old,new=save(f's{s}',im)
 metrics['scenes'][name]={'old_pairs':int(old.sum()),'new_pairs':int(new.sum()),'old_pairs_retained':int((old&new).sum())}
 Image.fromarray(im).save(A/f'{name}_input.png')
 for label,m in [('v15',old),('v16',new)]:
  overlay=im.copy();overlay[np.repeat(m,2,axis=1).astype(bool)]=255
  Image.fromarray(overlay).save(A/f'{name}_{label}_white_overlay.png')
assert all(metrics['scenes'][n]['new_pairs']<=metrics['scenes'][n]['old_pairs'] for n in names[:3])
assert metrics['scenes']['noise10']['new_pairs']<metrics['scenes']['noise10']['old_pairs']
assert metrics['scenes']['isolated']['new_pairs']==0
for n in names[4:9]+['circle','corner']:
 assert metrics['scenes'][n]['old_pairs']>0 and metrics['scenes'][n]['old_pairs_retained']==metrics['scenes'][n]['old_pairs'],n
assert metrics['scenes']['thin_diagonal']['old_pairs']==0 and metrics['scenes']['thin_diagonal']['new_pairs']>0
save('full',make(12,1280,720))
(D/'metrics.json').write_text(json.dumps(metrics,indent=2))
print('EDGE_DETAIL_FIXTURES_READY',json.dumps(metrics['scenes']))
