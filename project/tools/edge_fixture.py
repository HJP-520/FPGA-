from pathlib import Path
T=Path(__file__).resolve().parent.parent;D=T/'sim/edge_fixture';D.mkdir(exist_ok=True)
W,H=128,64
def pixel(scene,x,y):
 if scene==0:
  v=90
  if x%24==12 and y%16==8:v=250
  return (v,v,v)
 if scene==1:
  if 18<=x<54 and 12<=y<52:return (210,65,45)
  if (x-91)**2+(y-32)**2<21**2:return (32,190,155)
  return (35+x//2,45+y//3,75)
 if scene==2:
  v=210 if x>y+23 else 35
  return(v,v,v)
 if scene==3:
  v=100+((x*17+y*23)%7)-3
  return(v,v,v)
 if scene==4:
  v=35 if x<62 else 210
  return(v,v,v)
 # Bright background, dark thin contours and four independent pixel lanes.
 return (24,42,70) if x in (23,24,77,78) or y in (19,20,45,46) else (225,220,205)
def gray(p):return (p[0]>>2)+(p[1]>>1)+(p[2]>>2)
def edge(a,b,c,d,e,f,g,h,i):
 dx=[c-a,f-d,i-g];dy=[a-g,b-h,c-i]
 mag=abs(dx[0]+2*dx[1]+dx[2])+abs(dy[0]+2*dy[1]+dy[2])
 support=any(sum(v>=10 for v in ds)>=2 or sum(v<=-10 for v in ds)>=2 for ds in (dx,dy))
 return mag>=80 and support
def paint(p,on,mode):
 if mode==0:return p
 if mode==1:return (255,255,255) if on else (0,0,0)
 if mode==3:return (0,0,0) if on else tuple((c>>4)*17 for c in p)
 return (255,255,255) if on else p
def word(ps):return ''.join(''.join(f'{c:02x}'for c in p)for p in ps)
for scene in range(6):
 image=[[pixel(scene,x,y)for x in range(W)]for y in range(H)]
 pair=[[sum(gray(image[y][x+k])for k in range(2))//2 for x in range(0,W,2)]for y in range(H)]
 masks=[]
 for y in range(H):
  for xg in range(W//4):
   m=[]
   for lane in range(2):
    xx=2*xg+lane
    on=False
    if y>=2 and xx>0 and xx<W//2-1:
     on=edge(*(pair[yy][xx+dx]for yy in range(y-2,y+1)for dx in (-1,0,1)))
    m.append(on)
   masks.append(int(m[0])|int(m[1])<<1)
 inputs=[word(image[y][x:x+4])for y in range(H)for x in range(0,W,4)]
 (D/f'input{scene}.hex').write_text('\n'.join(inputs)+'\n')
 (D/f'mask{scene}.hex').write_text('\n'.join(f'{n:x}'for n in masks)+'\n')
 for mode in range(4):
  vals=[word([paint(image[y][x+k],bool(masks[y*(W//4)+x//4]&(1<<(k//2))),mode)for k in range(4)]) for y in range(H)for x in range(0,W,4)]
  (D/f'gold{scene}_{mode}.hex').write_text('\n'.join(vals)+'\n')
print('EDGE_FIXTURES_READY',6*4*W*H,'golden pixels')
