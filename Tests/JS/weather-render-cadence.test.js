// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');

test('balanced restores scale and motion while eco retains reduced cadences',()=>{
  const context=vm.createContext({URLSearchParams,window:{location:{search:''}}});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/three-renderer.js','utf8'),context);
  const balanced=context.getThreeQualityProfile();
  assert.ok(balanced.pixelRatio>=0.75);
  assert.ok(balanced.motionFps>=30);
  assert.ok(balanced.fps>=30);
  for(const condition of ['rain','freezing','snow','thunder','hail','clear'])
    assert.ok(context.getThreeMotionFps({quality:balanced},{condition})>=30,condition);
  context.window.aetherDesk={system:{qualityMode:'eco'}};
  const eco=context.getThreeQualityProfile();
  assert.equal(eco.name,'eco');assert.equal(eco.pixelRatio,0.4);
  assert.equal(eco.fps,6);assert.equal(eco.motionFps,15);assert.equal(eco.rainFps,6);
  for(const condition of ['rain','freezing'])assert.equal(context.getThreeMotionFps({quality:eco},{condition}),6,condition);
  for(const condition of ['clear','snow','thunder','hail'])assert.equal(context.getThreeMotionFps({quality:eco},{condition}),15,condition);
  context.window.aetherDesk.system.qualityMode='balanced';
  assert.equal(context.getThreeQualityProfile().name,'balanced');
  for(const cap of [15,30,60]){
    context.window.aetherDesk.system.fpsCap=cap;
    for(const condition of ['clear','rain','freezing','snow','thunder','hail'])
      assert.equal(context.getThreeMotionFps({quality:balanced},{condition}),cap,'balanced must match the native cap');
  }
  delete context.window.aetherDesk.system.fpsCap;
  context.window.aetherDesk.system.qualityMode='unknown';
  assert.equal(context.getThreeQualityProfile().name,'balanced');
});

test('live power-tier changes update resources and reset deadlines without recreating the renderer',()=>{
  const window={devicePixelRatio:2,location:{search:''},aetherDesk:{system:{qualityMode:'balanced'}}};
  const context=vm.createContext({URLSearchParams,window,S:{useThreeRenderer:true}});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/three-renderer.js','utf8'),context);
  let ratio,resizes=0;
  const renderer={setPixelRatio(value){ratio=value;},getPixelRatio(){return ratio;}};
  const state={quality:context.getThreeQualityProfile(),renderer,material:{defines:{USE_CLOUD_NOISE_CACHE:1},uniforms:{uCloudSteps:{},uCloudNoise:{}}},noiseTarget:{texture:{}},nextForegroundFrame:999,nextAtmosphereFrame:999,nextPresentationFrame:999};
  context.S.threeAtmosphere=state;
  for(const kind of ['Rain','Freezing','Snow','Hail'])context.S['three'+kind]={qualityCount:0,material:{uniforms:{uPixelRatio:{}}}};
  context.cssW=()=>1920;context.cssH=()=>1080;
  context.resizeThreeAtmosphere=(w,h)=>{assert.equal(w,1920);assert.equal(h,1080);resizes++;};
  for(const tier of ['eco','balanced']){
    window.aetherDesk.system.qualityMode=tier;
    context.syncThreeQualityProfile();
    assert.equal(state.quality.name,tier);
    assert.equal(ratio,state.quality.pixelRatio);
    assert.equal(state.material.uniforms.uCloudSteps.value,state.quality.steps);
    assert.equal(state.nextForegroundFrame,0);assert.equal(state.nextAtmosphereFrame,0);assert.equal(state.nextPresentationFrame,0);
    for(const kind of ['Rain','Freezing','Snow','Hail']){
      assert.equal(context.S['three'+kind].qualityCount,state.quality[kind.toLowerCase()+'Count']);
      assert.equal(context.S['three'+kind].material.uniforms.uPixelRatio.value,ratio);
    }
    assert.equal(state.renderer,renderer);
  }
  context.syncThreeQualityProfile();assert.equal(resizes,2);
});

test('balanced renders every 30 fps foreground callback for all weather conditions',()=>{
  for(const condition of ['clear','rain','freezing','snow','thunder','hail']){
    const context=vm.createContext({URLSearchParams,performance:{now:()=>1},window:{location:{search:''}},
      S:{renderer:'three',useThreeRenderer:true,atmosphere:{condition},animationFrameId:null,lastFrameTime:0,ctx:{clearRect(){}}}});
    for(const file of ['three-renderer.js','renderer.js'])vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/'+file,'utf8'),context);
    context.S.threeAtmosphere={quality:context.getThreeQualityProfile()};
    let paints=0;
    context.cssW=()=>1920;context.cssH=()=>1080;
    context.renderThreeAtmosphere=()=>{paints++;return false;};
    for(const name of ['renderThreePresentation','drawBgCelestial','updateParticles','drawParticles','syncRendererAnimation'])context[name]=()=>{};
    for(let n=1;n<=300;n++)context.render(n*1000/30);
    assert.equal(paints,300,condition);
  }
});

test('balanced keeps GPU motion at the cap while reusing an identical foreground',()=>{
  let now=1000,gpu=0,updates=0,clears=0,celestial=0,overlays=0;
  const context=vm.createContext({URLSearchParams,performance:{now:()=>1},window:{location:{search:''}},
    S:{renderer:'three',useThreeRenderer:true,props:{showParticles:true},weatherBucket:'snow',isDay:true,
      atmosphere:{condition:'snow',celestialVisibility:0.2,lightDiffusion:0.5},
      ctx:{clearRect(){clears++;}},lightningAlpha:0,lightningBoltAlpha:0,fogAlpha:0}});
  for(const file of ['three-renderer.js','renderer.js'])vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/'+file,'utf8'),context);
  context.S.threeAtmosphere={quality:context.getThreeQualityProfile()};
  context.cssW=()=>1920;context.cssH=()=>1080;context.wallpaperNow=()=>new Date(now);
  context.renderThreeAtmosphere=()=>false;context.renderThreePresentation=()=>{gpu++;};
  context.rendersThreeSnow=()=>true;context.getLunarPhase=()=>0.5;
  context.updateParticles=()=>{updates++;};context.drawBgCelestial=()=>{celestial++;};
  context.drawParticles=()=>{overlays++;};context.syncRendererAnimation=()=>{};
  for(let n=1;n<=30;n++)context.render(n*1000/30);
  assert.equal(gpu,30);assert.equal(updates,30);assert.equal(clears,1);assert.equal(celestial,1);assert.equal(overlays,1);
  now=2000;context.render(1034);assert.equal(clears,2,'current celestial position must repaint');
  context.S.lightningAlpha=0.1;context.render(1067);context.render(1100);
  assert.equal(clears,4,'storm flashes must paint every frame');
  context.S.lightningAlpha=0;context.render(1134);assert.equal(clears,5,'ended flashes must clear');
  context.S.atmosphere.celestialVisibility=0.7;context.render(1167);assert.equal(clears,6,'weather opacity must invalidate');
  context.S.threeAtmosphere.quality.pixelRatio=0.4;context.render(1200);assert.equal(clears,7,'quality resolution must invalidate');
  context.S.fogAlpha=0.1;context.render(1234);context.S.fogAlpha=0.2;context.render(1267);
  assert.equal(clears,9,'changing fog opacity must repaint');
  context.render(1300);assert.equal(clears,9,'steady fog can reuse identical pixels');
});

test('GPU skies skip Canvas star and volume-cloud physics while overlays and fallback keep updating',()=>{
  let clouds=0,volume=true;
  const star={tw:0,tws:1},context=vm.createContext({
    S:{useThreeRenderer:true,props:{showParticles:true,animationSpeed:1},atmosphere:{motionEnergy:0.5},
      weatherBucket:'clear',motionTime:0,stars:[star],lightningAlpha:0,lightningBoltAlpha:0,fogAlpha:0},
    cssW:()=>1920,cssH:()=>1080,precipitationGust:()=>1,precipitationWindDrift:()=>0,
    usesThreeCloudVolume:()=>volume});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/renderer.js','utf8'),context);
  context.updateClouds=()=>{clouds++;};context.precipitationGust=()=>1;context.precipitationWindDrift=()=>0;
  context.updateParticles(1/30);
  assert.equal(star.tw,0,'GPU stars must not also run Canvas physics');assert.equal(clouds,0);
  volume=false;context.updateParticles(1/30);assert.equal(clouds,1,'plane clouds still need their CPU positions');
  context.S.useThreeRenderer=false;context.updateParticles(1/30);
  assert.ok(star.tw>0,'Canvas fallback must resume star physics immediately');assert.equal(clouds,2);
  context.S.useThreeRenderer=true;volume=true;context.S.weatherBucket='thunder';
  context.S.lightningAlpha=0.2;context.S.lightningBoltAlpha=0.2;context.S.lightningCooldown=100;
  context.rendersThreeRain=()=>true;context.updateParticles(1/30);
  assert.ok(context.S.lightningAlpha>0&&context.S.lightningAlpha<0.2);
  context.S.weatherBucket='fog';context.S.fogAlpha=0.1;context.updateParticles(1/30);
  assert.equal(context.S.fogAlpha,0.10400000000000001);assert.equal(context.S.lightningAlpha,0);
});

test('GPU precipitation avoids unused Canvas lighting work and keeps the storm overlay',()=>{
  let lighting=0,flashes=0,bolts=0;
  const context=vm.createContext({S:{weatherBucket:'thunder',useThreeRenderer:true,props:{showParticles:true},
    atmosphere:{},windGust:1,lightningAlpha:0.2,fogAlpha:0},
    precipitationWindDrift:()=>0,wallpaperNow:()=>new Date(0),
    getPrecipitationLighting:()=>{lighting++;},rendersThreeRain:()=>true,
    rgba:()=>'',cssW:()=>1920,cssH:()=>1080});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/renderer.js','utf8'),context);
  context.drawLightningBolt=()=>{bolts++;};
  context.drawParticles({fillRect(){flashes++;}});
  assert.equal(lighting,0);assert.equal(flashes,1);assert.equal(bolts,1);
});

test('Canvas precipitation lighting and foreground reuse share the same predicate',()=>{
  const source=fs.readFileSync('Resources/Wallpapers/WeatherAether/js/renderer.js','utf8');
  for(const bucket of ['clear','partly','overcast','fog','rain','thunder','snow','freezing','hail'])for(let mask=0;mask<16;mask++){
    let lighting=0,paints=0,helperCalls=0;
    const gpu={rain:!!(mask&1),snow:!!(mask&2),freezing:!!(mask&4),hail:!!(mask&8)};
    const kind=bucket==='thunder'?'rain':bucket;
    const expected=Object.hasOwn(gpu,kind)&&!gpu[kind];
    const context=vm.createContext({performance:{now:()=>1},
      S:{renderer:'three',useThreeRenderer:true,props:{showParticles:true},weatherBucket:bucket,isDay:true,
        atmosphere:{condition:bucket,celestialVisibility:0,lightDiffusion:0.5},threeAtmosphere:{quality:{name:'eco',pixelRatio:0.4}},
        particles:[],windGust:1,lightningAlpha:0,lightningBoltAlpha:0,fogAlpha:0,ctx:{clearRect(){}}},
      rendersThreeRain:()=>gpu.rain,rendersThreeSnow:()=>gpu.snow,rendersThreeFreezing:()=>gpu.freezing,rendersThreeHail:()=>gpu.hail,
      getPrecipitationLighting:()=>{lighting++;return {};},getPrecipitationActivity:()=>0,lerp:()=>0,
      wallpaperNow:()=>new Date(0),cssW:()=>1920,cssH:()=>1080,
      syncThreeQualityProfile(){},claimThreeFrame:()=>true,getThreeMotionFps:()=>15,
      renderThreeAtmosphere:()=>false,renderThreePresentation(){},demoteRenderer:(renderer,error)=>{throw new Error(error);}});
    vm.runInContext(source,context);
    assert.equal(typeof context.usesCanvasPrecipitation,'function');
    const predicate=context.usesCanvasPrecipitation;
    assert.equal(predicate(bucket),expected,bucket+'/'+mask);
    context.usesCanvasPrecipitation=bk=>{helperCalls++;return predicate(bk);};
    const draw=context.drawParticles;
    context.drawParticles=ctx=>{paints++;draw(ctx);};
    for(const name of ['updateParticles','drawClouds','drawBgCelestial','drawLightningBolt','syncRendererAnimation'])context[name]=()=>{};
    context.precipitationWindDrift=()=>0;
    context.render(1000);context.render(1067);
    assert.equal(paints,expected?2:1,bucket+'/'+mask+': Canvas precipitation must prevent reuse');
    assert.equal(lighting,expected?paints:0,bucket+'/'+mask+': only Canvas precipitation needs lighting');
    assert.equal(helperCalls,2+paints,'both render and drawParticles must consult the helper');
  }
});

test('tiers reuse the solar raster while compositing current position and opacity',()=>{
  let diffusion=0.2,rasters=0,composites=0,canvases=0;
  const context=vm.createContext({window:{devicePixelRatio:2},
    document:{createElement(){canvases++;return {getContext(){return {setTransform(){}};}};}},
    S:{threeAtmosphere:{quality:{pixelRatio:0.75}},atmosphere:{lightDiffusion:diffusion}}});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/renderer.js','utf8'),context);
  context.drawBgSun=()=>{rasters++;};
  const target={drawImage(){composites++;}};
  for(let n=0;n<30;n++)context.drawCachedBgSun(target,n,30,32,n);
  assert.equal(rasters,1);assert.equal(composites,30);
  context.S.atmosphere.lightDiffusion=0.7;
  context.drawCachedBgSun(target,30,30,32,1000);assert.equal(rasters,2);
  context.drawCachedBgSun(target,30,30,40,1033);assert.equal(rasters,3);
  assert.equal(canvases,1,'solar cache refreshes must reuse one canvas');
});

test('balanced reuses lunar raster work while compositing the moving moon every frame',()=>{
  let phase=0.5,position=0.2,rasterizations=0,composites=0,canvases=0;
  const target={save(){},restore(){},drawImage(){composites++;}};
  const context=vm.createContext({URLSearchParams,window:{devicePixelRatio:2},
    document:{createElement(){canvases++;return {getContext(){return {setTransform(){}};}};}},
    S:{isDay:false,useThreeRenderer:true,threeAtmosphere:{quality:{name:'balanced',pixelRatio:0.75}},atmosphere:{celestialVisibility:1}}});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/renderer.js','utf8'),context);
  context.wallpaperNow=()=>new Date(0);
  context.getCelestialTrack=()=>({x:position,y:0.3});
  context.getLunarPhase=()=>phase;
  context.drawBgMoon=()=>{rasterizations++;};
  for(let frame=0;frame<30;frame++){position+=0.001;context.drawBgCelestial(target,1920,1080,frame*1000/30);}
  assert.equal(rasterizations,1,'unchanged lunar surface must not rebuild paths each frame');
  assert.equal(composites,30,'moon position must still be composited at the motion cap');
  phase=0.6;context.drawBgCelestial(target,1920,1080,1000);
  assert.equal(rasterizations,2,'lunar phase invalidates the raster');
  context.S.threeAtmosphere.quality.pixelRatio=0.8;
  context.drawBgCelestial(target,1920,1080,1033);
  assert.equal(rasterizations,3,'a resolution change invalidates the raster');
  context.S.threeAtmosphere.quality.name='eco';
  context.drawBgCelestial(target,1920,1080,1066);
  assert.equal(rasterizations,3,'eco also reuses its lunar raster');
  assert.equal(canvases,1,'lunar phase and resolution changes must reuse one canvas');
});

test('performance sampling reuses a bounded interval buffer across reporting windows',()=>{
  const context=vm.createContext({URLSearchParams,window:{location:{search:''}}});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/three-renderer.js','utf8'),context);
  const stats={startedAt:0,lastRenderedAt:0,frames:0,submitTotal:0,submitMax:0,intervals:[]};
  const intervals=stats.intervals,state={renderer:{domElement:{width:1440,height:810}}};
  let reports=0;
  for(let frame=1;frame<=900;frame++){
    const report=context.recordThreePerformance(stats,frame*1000/30,0.1,state,2);
    if(report){reports++;assert.ok(Math.abs(report.fps-30)<0.01);assert.equal(report.drawCalls,2);}
    assert.equal(stats.intervals,intervals);assert.ok(intervals.length<=61);
  }
  assert.ok(reports>=14);
});

test('hardware-filtered cloud noise preserves cubic interpolation across atlas seams',()=>{
  const context=vm.createContext({URLSearchParams,window:{location:{search:''}}});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/three-renderer.js','utf8'),context);
  const shader=context.THREE_SKY_FRAGMENT;
  function scalarFunction(name,parameters){
    const marker=name+'(';
    assert.ok(shader.includes(marker),name+' is required');
    const start=shader.indexOf('{',shader.indexOf(marker))+1;
    let end=start,depth=1;
    while(depth){const ch=shader[end++];if(ch==='{')depth++;if(ch==='}')depth--;}
    const body=shader.slice(start,end-1).replace(/\bfloat\b/g,'var').replace(/vec2 encoded=/g,'var encoded=');
    return 'function '+name+'('+parameters+'){'+body+'}\n';
  }
  const vec2=(x,y)=>({x,y}),vec3=(x,y,z)=>({x,y,z}),mix=(a,b,t)=>a+(b-a)*t;
  const mod=(x,n)=>x-Math.floor(x/n)*n;
  const hash=p=>{
    const x=Math.sin(mod(p.x,64)*17.1+mod(p.y,64)*23.7+mod(p.z,64)*31.3)*43758.5453;
    const scaled=(x-Math.floor(x))*255,high=Math.floor(scaled),low=Math.round((scaled-high)*255);
    return high/255+low/(255*255);
  };
  let filtered=0,nearest=0;
  function texture2D(texture,uv){
    filtered++;
    const x=uv.x*512-0.5,y=uv.y*512-0.5,ix=Math.floor(x),iy=Math.floor(y);
    const texel=(x,y)=>hash(vec3(x%64,y%64,Math.floor(x/64)+8*Math.floor(y/64)));
    const value=mix(mix(texel(ix,iy),texel(ix+1,iy),x-ix),mix(texel(ix,iy+1),texel(ix+1,iy+1),x-ix),y-iy);
    return {rg:vec2(value,0)};
  }
  assert.ok(!shader.includes('vec3 fieldSamples='),'empty cloud samples must not fetch lighting gradients');
  assert.ok(shader.indexOf('if(density<=0.0)continue;')<shader.indexOf('float gradientX=cloudNoise('));
  const source=scalarFunction('cloudNoiseSlice','ix,iy,iz,u,v')+scalarFunction('cachedNoise3','p')+
    'return function(p,offset){return vec3(cachedNoise3(p),cachedNoise3(vec3(p.x+offset,p.y,p.z)),cachedNoise3(vec3(p.x,p.y+offset,p.z)));};';
  const sample=new Function('hash3','texture2D','uCloudNoise','vec2','vec3','floor','mod','mix',source)(
    p=>{nearest++;return hash(p);},texture2D,{},vec2,vec3,Math.floor,mod,mix);
  function reference(p){
    const cell=vec3(Math.floor(p.x),Math.floor(p.y),Math.floor(p.z));
    const fade=t=>t*t*(3-2*t),u=fade(p.x-cell.x),v=fade(p.y-cell.y),w=fade(p.z-cell.z);
    let value=0;
    for(let x=0;x<=1;x++)for(let y=0;y<=1;y++)for(let z=0;z<=1;z++)
      value+=hash(vec3(cell.x+x,cell.y+y,cell.z+z))*(x?u:1-u)*(y?v:1-v)*(z?w:1-w);
    return value;
  }
  const points=[vec3(0.99,0.99,0.99),vec3(-1.01,-2.01,-3.01),vec3(1,2,3),vec3(-1.085,-1.17595,0),
    vec3(63.99,63.99,63.99),vec3(-64.01,127.99,-128.01)];
  for(let i=0;i<200;i++)points.push(vec3(Math.sin(i*1.7)*140,Math.cos(i*2.3)*140,Math.sin(i*0.7)*140));
  for(const p of points)for(const offset of [0,0.085,0.085*2.07,0.9]){
    const result=sample(p,offset);
    assert.ok(Math.abs(result.x-reference(p))<1e-10);
    assert.ok(Math.abs(result.y-reference(vec3(p.x+offset,p.y,p.z)))<1e-10);
    assert.ok(Math.abs(result.z-reference(vec3(p.x,p.y+offset,p.z)))<1e-10);
  }
  assert.ok(filtered>0);assert.ok(nearest>0,'tile boundaries must avoid filtering adjacent Z slices');
});

test('cloud-model selection parses unchanged preview options once and tracks URL changes',()=>{
  let parses=0;
  class SearchParams extends URLSearchParams {constructor(search){super(search);parses++;}}
  const window={location:{search:''}},context=vm.createContext({URLSearchParams:SearchParams,window});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/three-renderer.js','utf8'),context);
  for(let n=0;n<300;n++)assert.equal(context.usesThreeCloudVolume(),true);
  assert.equal(parses,1);
  window.location.search='?cloudModel=planes';
  for(let n=0;n<300;n++)assert.equal(context.usesThreeCloudVolume(),false);
  assert.equal(parses,2);
  window.location.search='?cloudModel=volume';assert.equal(context.usesThreeCloudVolume(),true);
  assert.equal(parses,3);
});

test('particle lighting caches clock reads while responding immediately to weather changes',()=>{
  const context=vm.createContext({URLSearchParams,window:{location:{search:''}}});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/three-renderer.js','utf8'),context);
  let reads=0,now=0;
  context.wallpaperNow=()=>{reads++;return new Date(now);};
  context.getCloudLightingKey=(atmosphere,date)=>atmosphere.condition+':'+atmosphere.isDay+':'+Math.floor(date.getTime()/900000);
  const atmosphere={condition:'rain',isDay:true};
  const first=context.getThreeLightingKey(atmosphere,1);
  for(let n=1;n<=29;n++)assert.equal(context.getThreeLightingKey(atmosphere,n*1000/30),first);
  assert.equal(reads,1,'unchanged lighting must not allocate a date each motion frame');
  now=900000;
  assert.notEqual(context.getThreeLightingKey(atmosphere,1001),first);
  atmosphere.condition='snow';context.getThreeLightingKey(atmosphere,1002);
  atmosphere.isDay=false;context.getThreeLightingKey(atmosphere,1003);
  assert.equal(reads,4);
});

test('noise-cache construction releases temporary resources and rejects failed or empty GPU data',()=>{
  const context=vm.createContext({URLSearchParams,window:{location:{search:''}},S:{}});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/three-renderer.js','utf8'),context);
  for(const failure of ['none','render','shader','empty']){
    const disposed={target:0,geometry:0,material:0},targets=[];
    let target,draws=0;
    const api={
      WebGLRenderTarget:class {constructor(width,height){Object.assign(this,{width,height,texture:{}});target=this;}dispose(){disposed.target++;}},
      Scene:class {add(){}},Mesh:class {},
      PlaneGeometry:class {dispose(){disposed.geometry++;}},
      ShaderMaterial:class {constructor(options){Object.assign(this,options);}dispose(){disposed.material++;}}
    };
    const state={camera:{},renderer:{
      setRenderTarget(value){targets.push(value);},
      render(){draws++;if(failure==='render')throw new Error('noise bake failed');if(failure==='shader')context.S.threeShaderError='noise shader failed';},
      readRenderTargetPixels(target,x,y,w,h,bytes){if(failure==='empty')return;for(let i=0;i<bytes.length;i+=4){bytes[i]=i/4;bytes[i+3]=255;}}
    }};
    if(failure==='none'){
      assert.equal(context.createThreeNoiseTarget(api,state),target);
      assert.equal(target.width,512);assert.equal(target.height,512);assert.equal(target.texture.generateMipmaps,false);
    }else assert.throws(()=>context.createThreeNoiseTarget(api,state),/noise|bake|shader/i);
    assert.equal(draws,1);assert.equal(targets[0],target);assert.equal(targets.at(-1),null);
    assert.equal(disposed.geometry,1);assert.equal(disposed.material,1);
    assert.equal(disposed.target,failure==='none'?0:1);
  }
});

test('cached tiers share one noise texture while showcase retains procedural noise',()=>{
  const context=vm.createContext({URLSearchParams,window:{location:{search:''}}});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/three-renderer.js','utf8'),context);
  const target={texture:{}},state={material:{defines:{},uniforms:{uCloudNoise:{}}}};
  let builds=0;context.createThreeNoiseTarget=()=>{builds++;return target;};
  for(const tier of ['showcase','eco','balanced','showcase','balanced']){
    state.quality=context.THREE_QUALITY_PROFILES[tier];context.setupThreeNoiseCache(state);
    const enabled=tier!=='showcase';
    assert.equal(state.material.defines.USE_CLOUD_NOISE_CACHE,enabled?1:0);
    assert.equal(state.material.uniforms.uCloudNoise.value,enabled?target.texture:null);
    assert.equal(builds,enabled||state.noiseTarget?1:0);
  }
  assert.equal(builds,1);
});

test('balanced trims cloud steps only for measured over-budget conditions',()=>{
  const context=vm.createContext({URLSearchParams,window:{location:{search:''}}});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/three-renderer.js','utf8'),context);
  for(const tier of ['balanced','eco','showcase']){
    const state={quality:context.THREE_QUALITY_PROFILES[tier]};
    for(const condition of ['clear','partly','overcast','fog','rain','freezing','snow','thunder','hail']){
      const expected=tier==='balanced'&&['partly','overcast','rain','freezing','thunder','hail'].includes(condition)?1:state.quality.steps;
      assert.equal(context.getThreeCloudSteps(state,{condition}),expected,tier+'/'+condition);
    }
  }
});

function simulate(condition,isDay,foregroundFps){
  const draws={sky:0,presentation:0,updates:0};
  const state={quality:{fps:15,motionFps:foregroundFps||30},scene:{},presentationScene:{},camera:{},atmosphereTarget:{}};
  state.renderer={info:{render:{calls:1}},setRenderTarget(){},render(scene){
    draws[scene===state.scene?'sky':'presentation']++;
  }};
  const context=vm.createContext({URLSearchParams,performance:{now:()=>0},
    S:{useThreeRenderer:true,threeAtmosphere:state,props:{showParticles:true},atmosphere:{condition,isDay}}});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/three-renderer.js','utf8'),context);
  context.updateThreeAtmosphere=()=>{};
  context.updateThreeClouds=()=>{};
  context.recordThreePerformance=()=>null;
  context.reportWeatherRendererStatus=()=>{};
  for(const [name,kind] of [['Rain','rain'],['Freezing','freezing'],['Snow','snow'],['Hail','hail']]){
    context['updateThree'+name]=()=>{
      draws.updates++;
      context.S['three'+name]={active:condition===kind||(kind==='rain'&&condition==='thunder')};
    };
  }
  function frame(timestamp){
    if(foregroundFps&&!context.claimThreeFrame(state,'nextForegroundFrame',timestamp,foregroundFps))return;
    const changed=context.renderThreeAtmosphere(timestamp);
    context.renderThreePresentation(timestamp,changed);
  }
  for(let frameNumber=1;frameNumber<=300;frameNumber++)frame(frameNumber*1000/30);
  return {draws,frame,context};
}

test('quiet skies cache their background while the foreground keeps ticking',()=>{
  for(const [condition,isDay] of [['clear',true],['fog',true],['fog',false]]){
    const {draws}=simulate(condition,isDay);
    assert.ok(draws.sky>=19&&draws.sky<=21,condition+': expected 2 background paints/second');
    assert.equal(draws.presentation,0,'a particle-free sky renders directly without a second pass');
    assert.equal(draws.updates,draws.sky*4,'update visibility only when the sky changes');
  }
});

test('starting precipitation refreshes the cached sky before its quiet deadline',()=>{
  const {draws,frame,context}=simulate('clear',true);
  const before=draws.sky;
  context.S.atmosphere={condition:'snow',isDay:true};
  frame(10001);
  assert.equal(draws.sky,before+1,'direct-to-screen sky must be copied into the particle background immediately');
  assert.equal(draws.presentation,1);
  context.S.atmosphere={condition:'clear',isDay:true};
  frame(10002);
  assert.equal(draws.sky,before+2,'ending precipitation must repaint directly immediately');
  assert.equal(draws.presentation,1,'no extra sky presentation pass');
});

test('snow keeps 30 fps motion over its cached sky and transitions resume clouds',()=>{
  const {draws,frame,context}=simulate('snow',true);
  assert.ok(draws.sky<=21,'snow background should be cached');
  assert.ok(draws.presentation>=290,'precipitation must retain its independent motion cadence');
  context.S.atmosphere={condition:'thunder',isDay:true};
  const before=draws.sky;
  for(let n=301;n<=330;n++)frame(n*1000/30);
  assert.ok(draws.sky-before>=8,'cloud rendering must resume after a weather change');
});

test('balanced combines equal-cadence volume sky and particles, then resumes cached snow',()=>{
  const {draws,frame,context}=simulate('thunder',true);
  const state=context.S.threeAtmosphere;
  context.window={location:{search:''},aetherDesk:{system:{fpsCap:30}}};
  state.quality={name:'balanced',fps:30,motionFps:60};
  state.material={sky:true};state.presentationMaterial={cached:true};
  state.presentationMesh={material:state.presentationMaterial};
  const before={...draws};
  state.renderer.render=scene=>{
    draws[scene===state.scene?'sky':'presentation']++;
    if(state.combinedSky)assert.equal(state.presentationMesh.material,state.material);
    else assert.equal(state.presentationMesh.material,state.presentationMaterial);
  };
  for(let n=301;n<=600;n++)frame(n*1000/30);
  assert.equal(draws.sky,before.sky,'combined mode must avoid the intermediate sky render');
  assert.equal(draws.presentation-before.presentation,300,'particles must retain 30 fps');
  assert.equal(state.presentationMesh.material,state.presentationMaterial,'cached material must be restored');
  context.S.atmosphere={condition:'snow',isDay:true};
  frame(20001);
  assert.equal(draws.sky,before.sky+1,'switching to a cached sky must populate its target immediately');
  assert.equal(state.combinedSky,false);
  context.S.atmosphere={condition:'thunder',isDay:true};
  context.window.aetherDesk.system.fpsCap=60;
  const sky=draws.sky,present=draws.presentation;
  for(let n=1;n<=60;n++)frame(20001+n*1000/60);
  assert.equal(state.combinedSky,false,'60 fps particles must retain independent sky caching');
  assert.ok(draws.sky-sky>=29&&draws.sky-sky<=31);
  assert.equal(draws.presentation-present,60);
  context.window.aetherDesk.system.fpsCap=30;
  state.renderer.render=()=>{throw new Error('GPU submission');};
  assert.throws(()=>frame(21034),/GPU submission/);
  assert.equal(state.presentationMesh.material,state.presentationMaterial,'failed draws must restore the cached material');
});

test('cloud refreshes do not postpone the independent precipitation deadline',()=>{
  const {draws}=simulate('thunder',true,24);
  assert.ok(draws.presentation>=239&&draws.presentation<=241,'expected 24 particle presentations/second');
});

test('rain and freezing can use a lower cadence without slowing snow or storms',()=>{
  for(const [condition,fps] of [['rain',10],['freezing',10],['snow',15],['thunder',15]]){
    const context=vm.createContext({URLSearchParams,performance:{now:()=>1},
      S:{renderer:'three',useThreeRenderer:true,atmosphere:{condition},
        threeAtmosphere:{quality:{motionFps:15,rainFps:10}},
        animationFrameId:null,lastFrameTime:0,ctx:{clearRect(){}}}});
    for(const file of ['three-renderer.js','renderer.js']){
      vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/'+file,'utf8'),context);
    }
    let paints=0;
    context.cssW=()=>1920;context.cssH=()=>1080;
    context.renderThreeAtmosphere=()=>{paints++;return false;};
    for(const name of ['renderThreePresentation','drawBgCelestial','updateParticles','drawParticles','syncRendererAnimation'])context[name]=()=>{};
    for(let n=1;n<=300;n++)context.render(n*1000/30);
    assert.ok(paints>=fps*10-1&&paints<=fps*10+1,condition+': incorrect quality cadence');
  }
});

test('the foreground obeys the quality cadence, keeps scheduling, and resumes Canvas immediately',()=>{
  const context=vm.createContext({URLSearchParams,performance:{now:()=>1},
    S:{renderer:'three',useThreeRenderer:true,threeAtmosphere:{quality:{motionFps:24}},
      animationFrameId:null,lastFrameTime:0,ctx:{clearRect(){}}}});
  for(const file of ['three-renderer.js','renderer.js']){
    vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/'+file,'utf8'),context);
  }
  let paints=0,scheduled=0,canvasPaints=0;
  context.cssW=()=>1920;context.cssH=()=>1080;
  context.renderThreeAtmosphere=()=>{paints++;return false;};
  for(const name of ['renderThreePresentation','drawBgCelestial','updateParticles','drawParticles'])context[name]=()=>{};
  context.syncRendererAnimation=()=>{scheduled++;};
  context.drawAtmosphericSky=()=>{canvasPaints++;};
  for(let n=1;n<=300;n++)context.render(n*1000/30);
  assert.ok(paints>=239&&paints<=241,'expected 24 foreground paints/second');
  assert.equal(scheduled,300,'skipping a paint must not stop the animation loop');
  context.S.useThreeRenderer=false;context.S.renderer='canvas';
  context.render(10001);
  assert.equal(canvasPaints,1,'Canvas fallback must not wait for the Three deadline');
});

test('the Three foreground shares the resolution budget without changing CSS coordinates',()=>{
  const canvas={width:3840,height:2160,style:{width:'1920px',height:'1080px'}};
  let transform;
  const vector={set(){}};
  const context=vm.createContext({URLSearchParams,window:{devicePixelRatio:2},
    WeatherAetherThree:{Vector2:function(){}},S:{useThreeRenderer:true,canvas,
      ctx:{setTransform(...values){transform=values;}},threeAtmosphere:{
        quality:{pixelRatio:0.55},renderer:{setSize(){},getDrawingBufferSize(){return {x:1056,y:594};}},
        camera:{updateProjectionMatrix(){}},material:{uniforms:{uViewportScale:{value:vector},uMinRatio:{}}},
        atmosphereTarget:{setSize(){}}
      }}});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/three-renderer.js','utf8'),context);
  context.resizeThreeAtmosphere(1920,1080);
  assert.equal(canvas.width,1056);
  assert.equal(canvas.height,594);
  assert.deepEqual(canvas.style,{width:'1920px',height:'1080px'});
  assert.deepEqual(transform,[0.55,0,0,0.55,0,0]);
});

test('night stars and moving clouds retain their quality cadence',()=>{
  for(const [condition,isDay] of [['clear',false],['partly',true],['thunder',false]]){
    const {draws}=simulate(condition,isDay);
    assert.ok(draws.sky>=145,condition+': animated sky must keep painting');
  }
});
