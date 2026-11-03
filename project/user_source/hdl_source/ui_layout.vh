always @(*)begin slot=0;lx=0;ly=0;large=0;length=0;col=0;row=0;fontbit=0;selected=0;
 if(visible&&x>=160&&x<480&&y>=16&&y<64)begin slot=1;lx=160;ly=16;large=1;length=10;end
 if(visible&&x>=160&&x<224&&y>=72&&y<96)begin slot=2;lx=160;ly=72;large=0;length=4;end
 if(tracking&&x>=768&&x<832&&y>=16&&y<40)begin slot=3;lx=768;ly=16;large=0;length=4;end
 if(tracking&&x>=960&&x<1024&&y>=16&&y<40)begin slot=4;lx=960;ly=16;large=0;length=4;end
 if(tracking&&x>=768&&x<832&&y>=44&&y<68)begin slot=5;lx=768;ly=44;large=0;length=4;end
 if(tracking&&cfg[0]&&x>=1024&&x<1088&&y>=64&&y<88)begin slot=6;lx=1024;ly=64;large=0;length=4;end
 if(tracking&&cfg[0]&&x>=1024&&x<1168&&y>=100&&y<124)begin slot=7;lx=1024;ly=100;large=0;length=9;end
 if(tracking&&cfg[0]&&x>=1024&&x<1168&&y>=128&&y<152)begin slot=8;lx=1024;ly=128;large=0;length=9;end
 if(tracking&&cfg[0]&&x>=1024&&x<1200&&y>=164&&y<188)begin slot=9;lx=1024;ly=164;large=0;length=11;end
 if(tracking&&cfg[0]&&x>=1024&&x<1216&&y>=196&&y<220)begin slot=10;lx=1024;ly=196;large=0;length=12;end
 if(tracking&&cfg[0]&&x>=16&&x<256&&y>=648&&y<672)begin slot=11;lx=16;ly=648;large=0;length=15;end
 if(tracking&&cfg[0]&&x>=336&&x<576&&y>=648&&y<672)begin slot=12;lx=336;ly=648;large=0;length=15;end
 if(tracking&&cfg[0]&&x>=656&&x<896&&y>=648&&y<672)begin slot=13;lx=656;ly=648;large=0;length=15;end
 if(tracking&&cfg[0]&&x>=976&&x<1216&&y>=648&&y<672)begin slot=14;lx=976;ly=648;large=0;length=15;end
 if(tracking&&!cfg[0]&&x>=16&&x<256&&y>=688&&y<712)begin slot=11;lx=16;ly=688;large=0;length=15;end
 if(tracking&&!cfg[0]&&x>=336&&x<576&&y>=688&&y<712)begin slot=12;lx=336;ly=688;large=0;length=15;end
 if(tracking&&!cfg[0]&&x>=656&&x<896&&y>=688&&y<712)begin slot=13;lx=656;ly=688;large=0;length=15;end
 if(tracking&&!cfg[0]&&x>=976&&x<1216&&y>=688&&y<712)begin slot=14;lx=976;ly=688;large=0;length=15;end
 if(visible&&!tracking&&x>=16&&x<256&&y>=688&&y<712)begin slot=11;lx=16;ly=688;large=0;length=15;end
 if(visible&&!tracking&&x>=336&&x<576&&y>=688&&y<712)begin slot=12;lx=336;ly=688;large=0;length=15;end
 if(visible&&!tracking&&x>=656&&x<896&&y>=688&&y<712)begin slot=13;lx=656;ly=688;large=0;length=15;end
 if(visible&&!tracking&&x>=976&&x<1216&&y>=688&&y<712)begin slot=14;lx=976;ly=688;large=0;length=15;end
 if(tracking&&cfg[0]&&x>=32&&x<176&&y>=688&&y<712)begin slot=15;lx=32;ly=688;large=0;length=9;end
 if(tracking&&cfg[0]&&x>=352&&x<496&&y>=688&&y<712)begin slot=16;lx=352;ly=688;large=0;length=9;end
 if(tracking&&cfg[0]&&x>=672&&x<816&&y>=688&&y<712)begin slot=17;lx=672;ly=688;large=0;length=9;end
 if(tracking&&cfg[0]&&x>=992&&x<1136&&y>=688&&y<712)begin slot=18;lx=992;ly=688;large=0;length=9;end
 if(axes&&x>=128&&x<192&&y>=368&&y<392)begin slot=19;lx=128;ly=368;large=0;length=4;end
 if(axes&&x>=288&&x<352&&y>=368&&y<392)begin slot=20;lx=288;ly=368;large=0;length=4;end
 if(axes&&x>=448&&x<512&&y>=368&&y<392)begin slot=21;lx=448;ly=368;large=0;length=4;end
 if(axes&&x>=768&&x<832&&y>=368&&y<392)begin slot=22;lx=768;ly=368;large=0;length=4;end
 if(axes&&x>=928&&x<992&&y>=368&&y<392)begin slot=23;lx=928;ly=368;large=0;length=4;end
 if(axes&&x>=1088&&x<1152&&y>=368&&y<392)begin slot=24;lx=1088;ly=368;large=0;length=4;end
 if(axes&&x>=652&&x<716&&y>=108&&y<132)begin slot=25;lx=652;ly=108;large=0;length=4;end
 if(axes&&x>=652&&x<716&&y>=228&&y<252)begin slot=26;lx=652;ly=228;large=0;length=4;end
 if(axes&&x>=652&&x<716&&y>=468&&y<492)begin slot=27;lx=652;ly=468;large=0;length=4;end
 if(axes&&x>=652&&x<716&&y>=588&&y<612)begin slot=28;lx=652;ly=588;large=0;length=4;end
 if(axes&&x>=652&&x<668&&y>=368&&y<392)begin slot=29;lx=652;ly=368;large=0;length=1;end
 if(axes&&x>=1256&&x<1272&&y>=332&&y<356)begin slot=30;lx=1256;ly=332;large=0;length=1;end
 if(axes&&x>=652&&x<668&&y>=0&&y<24)begin slot=31;lx=652;ly=0;large=0;length=1;end
 if(tracking&&tv&&x>=1120&&x<1184&&y>=16&&y<40)begin slot=32;lx=1120;ly=16;large=0;length=4;end
 if(slot!=0)begin col=large?((x-lx)>>5):((x-lx)>>4);row=large?((y-ly)>>1):(y-ly);fontbit=large?((x-lx)>>1):(x-lx);end
 if(slot>=11&&slot<=14)begin
  if(cfg[11:10]==1)selected=(slot==11&&cfg[9:8]==0)||(slot==12&&cfg[9:8]==2)||(slot==13&&cfg[9:8]==1)||(slot==14&&cfg[9:8]==3);
  else if(cfg[11:10]==2)selected=(slot==11&&cfg[7:6]==0)||(slot==12&&cfg[7:6]==2)||(slot==13&&cfg[7:6]==1);
 end
end
