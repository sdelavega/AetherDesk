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
    assert.equal(draws.presentation,draws.sky,'no redundant presentation of an unchanged quiet sky');
    assert.equal(draws.updates,draws.presentation*4,'update uniforms only for presented frames');
  }
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
