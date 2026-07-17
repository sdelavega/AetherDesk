'use strict';

var THREE_SKY_VERTEX=[
  'varying vec2 vUv;',
  'void main(){',
  '  vUv=uv;',
  '  gl_Position=vec4(position.xy,0.0,1.0);',
  '}'
].join('\n');

var THREE_SKY_FRAGMENT=[
  'precision mediump float;',
  'varying vec2 vUv;',
  'uniform vec3 uTop;',
  'uniform vec3 uMiddle;',
  'uniform vec3 uBottom;',
  'uniform vec3 uLightColor;',
  'uniform vec2 uLightPosition;',
  'uniform vec2 uViewportScale;',
  'uniform float uHaze;',
  'uniform float uDiffusion;',
  'uniform float uLightAlpha;',
  'uniform float uCloudDensity;',
  'uniform float uMinRatio;',
  'uniform float uStarVisibility;',
  'uniform float uCloudCover;',
  'uniform float uCloudVolumeEnabled;',
  'uniform vec2 uCloudWind;',
  'uniform vec3 uCloudHighlight;',
  'uniform vec3 uCloudShadow;',
  'uniform vec3 uCloudLightOffset;',
  'uniform float uCloudLightBase;',
  'uniform float uCloudLightStrength;',
  'uniform float uCloudTopLight;',
  'uniform float uTime;',
  'float hash(vec2 p){',
  '  return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453123);',
  '}',
  'float hash3(vec3 p){',
  '  p=fract(p*0.1031);',
  '  p+=dot(p,p.yzx+33.33);',
  '  return fract((p.x+p.y)*p.z);',
  '}',
  'float noise3(vec3 p){',
  '  vec3 i=floor(p);',
  '  vec3 f=fract(p);',
  '  f=f*f*(3.0-2.0*f);',
  '  return mix(mix(mix(hash3(i),hash3(i+vec3(1.0,0.0,0.0)),f.x),mix(hash3(i+vec3(0.0,1.0,0.0)),hash3(i+vec3(1.0,1.0,0.0)),f.x),f.y),mix(mix(hash3(i+vec3(0.0,0.0,1.0)),hash3(i+vec3(1.0,0.0,1.0)),f.x),mix(hash3(i+vec3(0.0,1.0,1.0)),hash3(i+vec3(1.0,1.0,1.0)),f.x),f.y),f.z);',
  '}',
  'float cloudNoise(vec3 p){',
  '  return noise3(p)*0.68+noise3(p*2.07+7.4)*0.32;',
  '}',
  'void main(){',
  '  float lower=smoothstep(0.0,0.52,vUv.y);',
  '  float upper=smoothstep(0.42,1.0,vUv.y);',
  '  vec3 color=mix(uBottom,uMiddle,lower);',
  '  color=mix(color,uTop,upper);',
  '  vec2 starGrid=vec2(180.0,100.0);',
  '  vec2 starCell=floor(vUv*starGrid);',
  '  vec2 starLocal=fract(vUv*starGrid)-0.5;',
  '  float starSeed=hash(starCell);',
  '  float starRadius=mix(0.035,0.105,hash(starCell+17.3));',
  '  float starPoint=(1.0-smoothstep(starRadius,starRadius*2.1,length(starLocal)))*step(0.9945,starSeed);',
  '  float twinkle=0.62+0.38*sin(uTime*(0.7+hash(starCell+4.1)*1.8)+starSeed*20.0);',
  '  float horizonFade=smoothstep(0.10,0.42,vUv.y);',
  '  color+=vec3(0.84,0.89,1.0)*starPoint*twinkle*horizonFade*uStarVisibility;',
  '  float hazeField=1.0-smoothstep(0.0,0.46,vUv.y);',
  '  float hazeAlpha=(0.025+uHaze*0.16)*hazeField;',
  '  color=mix(color,vec3(0.863,0.882,0.910),hazeAlpha);',
  '  vec2 lightDelta=(vUv-uLightPosition)*uViewportScale;',
  '  float lightRadius=0.48+uDiffusion*0.20;',
  '  float airlight=1.0-smoothstep(0.0,lightRadius,length(lightDelta));',
  '  color=mix(color,uLightColor,airlight*uLightAlpha);',
  '  if(uCloudVolumeEnabled>0.5){',
  '    vec2 view=(vUv-vec2(0.5,0.64))*vec2(uViewportScale.x/max(0.001,uViewportScale.y),1.0);',
  '    vec3 ray=normalize(vec3(view*0.78,1.25));',
  '    vec3 origin=vec3(view*0.58,-0.35);',
  '    vec4 cloud=vec4(0.0);',
  '    float threshold=mix(0.74,0.43,uCloudCover);',
  '    for(int i=0;i<7;i++){',
  '      float stepT=(float(i)+0.5)/7.0;',
  '      vec3 samplePos=origin+ray*(stepT*1.75);',
  '      samplePos.xy+=uCloudWind*uTime*0.012;',
  '      samplePos.x+=sin(uTime*0.021+stepT*5.0)*0.035;',
  '      float vertical=smoothstep(-0.28,0.02,samplePos.y)*(1.0-smoothstep(0.38,0.78,samplePos.y));',
  '      float density=smoothstep(threshold,threshold+0.16,cloudNoise(samplePos*2.15))*vertical*uCloudDensity;',
  '      float towardLight=cloudNoise((samplePos+uCloudLightOffset)*2.15);',
  '      float crown=smoothstep(-0.08,0.48,samplePos.y);',
  '      float illumination=clamp(uCloudLightBase+(towardLight-density)*uCloudLightStrength+crown*uCloudTopLight,0.04,1.0);',
  '      vec3 cloudColor=mix(uCloudShadow,uCloudHighlight,illumination);',
  '      float alpha=density*0.24*(1.0-cloud.a);',
  '      cloud.rgb+=cloudColor*alpha;',
  '      cloud.a+=alpha;',
  '    }',
  '    float cloudBand=smoothstep(0.42,0.58,vUv.y)*(1.0-smoothstep(0.96,1.0,vUv.y));',
  '    color=mix(color,cloud.rgb/max(cloud.a,0.001),cloud.a*cloudBand);',
  '  }',
  '  vec2 edgeDelta=(vUv-vec2(0.5,0.52))*uViewportScale;',
  '  float vignette=smoothstep(uMinRatio*0.22,0.78,length(edgeDelta));',
  '  color*=1.0-vignette*(0.035+uCloudDensity*0.035);',
  '  float grain=hash(gl_FragCoord.xy+floor(uTime*2.0))-0.5;',
  '  color+=grain/255.0;',
  '  gl_FragColor=vec4(color,1.0);',
  '}'
].join('\n');

function threeColor(c){
  return new WeatherAetherThree.Color(c[0]/255,c[1]/255,c[2]/255);
}

function initializeThreeAtmosphere(){
  if(new URLSearchParams(window.location.search).get('renderer')==='canvas')return false;
  var api=window.WeatherAetherThree;
  var canvas=document.getElementById('wa-webgl');
  if(!api||!canvas)return false;
  try{
    var renderer=new api.WebGLRenderer({
      canvas:canvas,antialias:false,alpha:false,depth:false,stencil:false,
      powerPreference:'low-power',failIfMajorPerformanceCaveat:true
    });
    renderer.setPixelRatio(Math.min(window.devicePixelRatio||1,0.85));
    var scene=new api.Scene();
    var camera=new api.PerspectiveCamera(45,1,0.1,20);
    camera.position.set(0,0,5);
    var material=new api.ShaderMaterial({
      vertexShader:THREE_SKY_VERTEX,fragmentShader:THREE_SKY_FRAGMENT,
      depthTest:false,depthWrite:false,
      uniforms:{
        uTop:{value:new api.Color()},uMiddle:{value:new api.Color()},uBottom:{value:new api.Color()},
        uLightColor:{value:new api.Color()},uLightPosition:{value:new api.Vector2(0.5,0.5)},
        uViewportScale:{value:new api.Vector2(1,1)},uHaze:{value:0},uDiffusion:{value:0},
        uLightAlpha:{value:0},uCloudDensity:{value:0},uMinRatio:{value:1},
        uStarVisibility:{value:0},uCloudCover:{value:0},uCloudVolumeEnabled:{value:0},
        uCloudWind:{value:new api.Vector2(0,0)},uCloudHighlight:{value:new api.Color()},
        uCloudShadow:{value:new api.Color()},uCloudLightOffset:{value:new api.Vector3(-0.20,0.16,0.10)},
        uCloudLightBase:{value:0.34},uCloudLightStrength:{value:0.82},uCloudTopLight:{value:0.12},
        uTime:{value:0}
      }
    });
    var geometry=new api.PlaneGeometry(2,2);
    var skyMesh=new api.Mesh(geometry,material);
    skyMesh.frustumCulled=false;skyMesh.renderOrder=-100;
    scene.add(skyMesh);
    S.threeAtmosphere={renderer:renderer,scene:scene,camera:camera,material:material,lastPaintKey:null,lastFrame:0};
    S.useThreeRenderer=true;canvas.style.display='block';
    return true;
  }catch(error){
    S.useThreeRenderer=false;S.threeAtmosphere=null;canvas.style.display='none';
    console.warn('Weather Aether: WebGL atmosphere unavailable; using Canvas fallback.',error);
    return false;
  }
}

function usesThreeCloudVolume(){
  return new URLSearchParams(window.location.search).get('cloudModel')!=='planes';
}

// Low sunlight benefits from dramatic lateral shading, but reusing that model
// at every hour makes noon clouds look under-lit and night clouds look carved.
// Keep the horizon treatment, rotate the light overhead around noon, and let
// night settle into subdued ambient moonlight.
function getThreeCloudShading(atmosphere,track){
  if(!atmosphere.isDay){
    return{offset:[(track.x-0.5)*0.18,0.10,0.08],base:0.11,strength:0.20,top:0.045};
  }
  var overhead=Math.max(0,Math.min(1,(track.elevation-0.18)/0.64));
  overhead=overhead*overhead*(3-2*overhead);
  return{
    offset:[lerp(-0.20,(track.x-0.5)*0.08,overhead),lerp(0.16,0.34,overhead),lerp(0.10,0.04,overhead)],
    base:lerp(0.34,0.50,overhead),
    strength:lerp(0.82,0.34,overhead),
    top:lerp(0.12,0.30,overhead)
  };
}

function resizeThreeAtmosphere(w,h){
  if(!S.useThreeRenderer||!S.threeAtmosphere)return;
  S.threeAtmosphere.renderer.setSize(w,h,false);
  S.threeAtmosphere.camera.aspect=w/Math.max(1,h);
  S.threeAtmosphere.camera.updateProjectionMatrix();
  var maxDimension=Math.max(w,h);
  var uniforms=S.threeAtmosphere.material.uniforms;
  uniforms.uViewportScale.value.set(w/maxDimension,h/maxDimension);
  uniforms.uMinRatio.value=Math.min(w,h)/maxDimension;
}

function makeThreeCloudTexture(canvas){
  var api=window.WeatherAetherThree;
  var texture=new api.CanvasTexture(canvas);
  texture.colorSpace=api.SRGBColorSpace;
  return texture;
}

function clearThreeClouds(){
  var state=S.threeAtmosphere,cloudState=S.threeClouds;
  if(!state||!cloudState)return;
  for(var i=0;i<cloudState.meshes.length;i++){
    state.scene.remove(cloudState.meshes[i]);
    cloudState.meshes[i].material.dispose();
  }
  for(var i=0;i<cloudState.textures.length;i++)cloudState.textures[i].dispose();
  if(cloudState.geometry)cloudState.geometry.dispose();
  S.threeClouds=null;
}

function refreshThreeCloudTextures(){
  var api=window.WeatherAetherThree,cloudState=S.threeClouds;
  if(!S.useThreeRenderer||!api||!cloudState)return;
  for(var i=0;i<cloudState.textures.length;i++)cloudState.textures[i].dispose();
  cloudState.textures=[];
  for(var i=0;i<S.cloudSprites.length;i++)cloudState.textures.push(makeThreeCloudTexture(S.cloudSprites[i]));
  for(var i=0;i<cloudState.meshes.length;i++){
    cloudState.meshes[i].material.map=cloudState.textures[S.clouds[i].sprite];
    cloudState.meshes[i].material.needsUpdate=true;
  }
}

function rebuildThreeClouds(){
  if(usesThreeCloudVolume()||!S.useThreeRenderer||!S.threeAtmosphere||S.clouds.length===0)return;
  var api=window.WeatherAetherThree;
  var geometry=new api.PlaneGeometry(1,1);
  var textures=[];
  for(var i=0;i<S.cloudSprites.length;i++)textures.push(makeThreeCloudTexture(S.cloudSprites[i]));
  var meshes=[];
  for(var i=0;i<S.clouds.length;i++){
    var cloud=S.clouds[i];
    var material=new api.MeshBasicMaterial({
      map:textures[cloud.sprite],transparent:true,opacity:cloud.opacity,
      depthTest:true,depthWrite:false
    });
    var mesh=new api.Mesh(geometry,material);
    mesh.position.z=0.25+cloud.depth*2.25;
    mesh.rotation.z=((cloud.sprite%4)-1.5)*0.008;
    mesh.renderOrder=Math.round(cloud.depth*100);
    S.threeAtmosphere.scene.add(mesh);meshes.push(mesh);
  }
  S.threeClouds={geometry:geometry,textures:textures,meshes:meshes};
}

function updateThreeClouds(timestamp){
  var state=S.threeAtmosphere,cloudState=S.threeClouds;
  if(!state||!cloudState)return;
  var camera=state.camera,w=cssW(),h=cssH();
  camera.position.x=Math.sin(timestamp*0.000031)*0.035;
  camera.position.y=Math.sin(timestamp*0.000019+1.2)*0.018;
  camera.lookAt(0,0,0);
  for(var i=0;i<cloudState.meshes.length;i++){
    var cloud=S.clouds[i],mesh=cloudState.meshes[i];
    if(!cloud||!mesh)continue;
    var distance=camera.position.z-mesh.position.z;
    var viewHeight=2*Math.tan(camera.fov*Math.PI/360)*distance;
    var viewWidth=viewHeight*camera.aspect;
    mesh.position.x=((cloud.x+cloud.width*0.5)/w-0.5)*viewWidth;
    mesh.position.y=(0.5-(cloud.y+cloud.height*0.5)/h)*viewHeight;
    mesh.scale.set((cloud.width/w)*viewWidth,(cloud.height/h)*viewHeight,1);
    mesh.material.opacity=cloud.opacity;
  }
}

function updateThreeAtmosphere(timestamp){
  var state=S.threeAtmosphere;
  var atmosphere=S.atmosphere||deriveAtmosphericState(S.weather);
  var now=wallpaperNow();
  var key=[Math.floor(now.getTime()/15000),atmosphere.condition,atmosphere.isDay?1:0].join(':');
  var uniforms=state.material.uniforms;
  if(state.lastPaintKey!==key){
    var colors=getPhaseColors();
    var track=getCelestialTrack(now,atmosphere.isDay);
    var lightColor=lerpC([225,238,255],[255,155,72],track.horizonWarmth);
    uniforms.uTop.value.copy(threeColor(colors.top));
    uniforms.uMiddle.value.copy(threeColor(colors.mid));
    uniforms.uBottom.value.copy(threeColor(colors.bot));
    uniforms.uLightColor.value.copy(threeColor(lightColor));
    uniforms.uLightPosition.value.set(track.x,Math.min(0.66,1-track.y));
    uniforms.uHaze.value=atmosphere.horizonHaze;
    uniforms.uDiffusion.value=atmosphere.lightDiffusion;
    uniforms.uLightAlpha.value=(0.055+atmosphere.lightDiffusion*0.09)*(atmosphere.isDay?1:0.34);
    uniforms.uCloudDensity.value=atmosphere.cloudDensity;
    uniforms.uCloudCover.value=atmosphere.cloudCover;
    uniforms.uCloudVolumeEnabled.value=usesThreeCloudVolume()&&atmosphere.cloudCover>=0.10&&
      atmosphere.condition!=='fog'&&atmosphere.condition!=='snow'?1:0;
    var cloudLight=getCloudLighting(atmosphere,now);
    uniforms.uCloudHighlight.value.copy(threeColor(cloudLight.highlight));
    uniforms.uCloudShadow.value.copy(threeColor(cloudLight.shadow));
    var cloudShading=getThreeCloudShading(atmosphere,track);
    uniforms.uCloudLightOffset.value.set(cloudShading.offset[0],cloudShading.offset[1],cloudShading.offset[2]);
    uniforms.uCloudLightBase.value=cloudShading.base;
    uniforms.uCloudLightStrength.value=cloudShading.strength;
    uniforms.uCloudTopLight.value=cloudShading.top;
    var windToward=((atmosphere.windDirection+180)%360)*Math.PI/180;
    uniforms.uCloudWind.value.set(Math.sin(windToward)*atmosphere.motionEnergy,Math.cos(windToward)*atmosphere.motionEnergy*0.12);
    state.lastPaintKey=key;
  }
  uniforms.uStarVisibility.value=!atmosphere.isDay&&S.props.showParticles?
    (atmosphere.condition==='clear'?1:atmosphere.condition==='partly'?0.38:0):0;
  uniforms.uTime.value=timestamp/1000;
}

function renderThreeAtmosphere(timestamp){
  var state=S.threeAtmosphere;
  if(!S.useThreeRenderer||!state)return;
  // Atmospheric motion does not benefit from 60 fps. Canvas precipitation can
  // remain responsive while the volumetric WebGL background stays at 24 fps.
  if(timestamp-state.lastFrame<1000/24)return;
  updateThreeAtmosphere(timestamp);
  updateThreeClouds(timestamp);
  state.renderer.render(state.scene,state.camera);
  state.lastFrame=timestamp;
}
