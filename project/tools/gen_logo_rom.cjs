// npm install sharp; node tools/gen_logo_rom.cjs
// Deterministic reference conversion, no generated/retypeset lettering.
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');
const root = path.resolve(__dirname,'..');
(async()=>{
 const source=path.join(root,'assets/anlogic_reference.png');
 const palette=JSON.parse(fs.readFileSync(path.join(root,'assets/palette.json'),'utf8'));
 const {data}=await sharp(source).extract({left:108,top:88,width:916,height:280})
   .resize(256,80,{fit:'fill',kernel:'lanczos3'}).removeAlpha().raw().toBuffer({resolveWithObject:true});
 const indices=[],rgb=Buffer.alloc(256*80*3),gold=[];
 for(let i=0;i<256*80;i++){
   let best=1,error=Infinity;
   for(let k=1;k<16;k++){
     let e=0;for(let c=0;c<3;c++)e+=(data[i*3+c]-palette[k][c])**2;
     if(e<error){error=e;best=k;}
   }
   indices.push(best);
   for(let c=0;c<3;c++)rgb[i*3+c]=palette[best][c];
   gold.push(palette[best].map(v=>v.toString(16).padStart(2,'0')).join(''));
 }
 let hex='';
 for(let i=0;i<indices.length;i+=2)hex+=(indices[i]|indices[i+1]<<4).toString(16).padStart(2,'0')+'\n';
 fs.writeFileSync(path.join(root,'user_source/hdl_source/ui/logo_mem.hex'),hex);
 fs.writeFileSync(path.join(root,'assets/logo_rgb888.hex'),gold.join('\n')+'\n');
 await sharp(rgb,{raw:{width:256,height:80,channels:3}}).png().toFile(path.join(root,'assets/logo_native.png'));
 await sharp(rgb,{raw:{width:256,height:80,channels:3}}).resize(1024,320,{kernel:'nearest'}).png().toFile(path.join(root,'assets/logo_pixels_4x.png'));
 console.log('256x80 4bpp logo ROM and previews updated.');
})().catch(e=>{console.error(e);process.exitCode=1;});
