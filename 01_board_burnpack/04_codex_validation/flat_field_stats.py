"""Compare neutral-target channel ratios; does not infer or apply an LSC map."""
from pathlib import Path
import argparse,json
import numpy as np
from PIL import Image

def analyze(path):
    a=np.array(Image.open(path).convert('RGB'),dtype=np.float64)
    h,w,_=a.shape
    results={}
    for name,cx,cy in [('center',.5,.5),('top_left',.15,.15),('top_right',.85,.15),('bottom_left',.15,.85),('bottom_right',.85,.85)]:
        x0,x1=int((cx-.05)*w),int((cx+.05)*w)
        y0,y1=int((cy-.05)*h),int((cy+.05)*h)
        roi=a[y0:y1,x0:x1].reshape(-1,3)
        if not len(roi):raise ValueError('Image too small for region statistics')
        eligible=(roi.max(axis=1)<250)&(roi.min(axis=1)>15)
        pixels=roi[eligible]
        mean=pixels.mean(axis=0) if len(pixels) else None
        results[name]={'box':[x0,y0,x1,y1],'usable_pixels':int(len(pixels)),
            'clipped_pixel_fraction':float((roi.max(axis=1)>=250).mean()),
            'mean_rgb':mean.tolist() if mean is not None else None,
            'g_over_r':float(mean[1]/mean[0]) if mean is not None else None,
            'g_over_b':float(mean[1]/mean[2]) if mean is not None else None}
    return {'image':str(Path(path).resolve()),'size':[w,h],'regions':results,
            'interpretation':'Use an evenly lit neutral target, avoiding clipping. Ratios show spatial color differences; illumination, lens/sensor shading, camera pipeline, and display/capture processing must still be distinguished. No automatic correction coefficients are generated.'}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('image');p.add_argument('--output',default='flat_field_stats.json')
    args=p.parse_args();r=analyze(args.image)
    Path(args.output).write_text(json.dumps(r,indent=2,ensure_ascii=False),encoding='utf-8')
    print(json.dumps(r,indent=2,ensure_ascii=False))
