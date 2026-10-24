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

// Model a mobile mediump implementation using binary16 range and precision.
// Desktop WebKit may use float32 even when the shader requests mediump.
function half(value){
  if(!Number.isFinite(value)||value===0)return value;
  const step=2**Math.max(-24,Math.floor(Math.log2(Math.abs(value)))-10);
  const rounded=Math.round(value/step)*step;
  return Math.abs(rounded)>65504?Math.sign(rounded)*Infinity:rounded;
}

test('sky grain stays finite across the viewport on mobile shader precision',()=>{
  const context=vm.createContext({});
  vm.runInContext(fs.readFileSync('Resources/Wallpapers/WeatherAether/js/three-renderer.js','utf8'),context);
  const shader=context.THREE_SKY_FRAGMENT;
  const definition=shader.match(/(?:(highp|mediump)\s+)?float hash\((?:(highp|mediump)\s+)?vec2 p\)\s*\{([^}]+)\}/);
  assert.ok(definition,'locate the production pixel hash');
  const defaultPrecision=shader.match(/precision\s+(highp|mediump)\s+float/)[1];
  const precision=definition[2]||defaultPrecision;
  const round=precision==='highp'?Math.fround:half;
  // Evaluate the production expression with rounding at every arithmetic
  // operation. Read coefficients from GLSL so a shader edit cannot drift.
  const expression=definition[3].match(/return fract\(sin\(dot\(p,vec2\(([\d.]+),([\d.]+)\)\)\)\*([\d.]+)\);/);
  assert.ok(expression,'the scalar hash evaluator must cover the production expression');
  const [,a,b,scale]=expression.map(Number);
  function hash(x,y){
    const dot=round(round(round(x)*round(a))+round(round(y)*round(b)));
    const value=round(round(Math.sin(dot))*round(scale));
    return value-Math.floor(value);
  }
  assert.equal(half(70000),Infinity,'the model must expose mediump overflow');
  const sizes=[[2560,1600],[2520,1080],[1600,1200],[1080,1920],[1365,769]];
  for(const tier of ['balanced','eco'])for(const [width,height] of sizes){
    const ratio=context.THREE_QUALITY_PROFILES[tier].pixelRatio;
    const w=Math.floor(width*ratio),h=Math.floor(height*ratio);
    for(const time of [0,4,43200])for(const [x,y] of [[0.5,0.5],[w-0.5,0.5],[0.5,h-0.5],[w-0.5,h-0.5],[w/2,h/2]]){
      const grain=hash(x+time,y+time)-0.5;
      assert.ok(Number.isFinite(grain)&&grain>=-0.5&&grain<0.5,
        `${tier} ${width}x${height}, pixel ${x},${y}, time ${time}: grain=${grain} (${precision})`);
    }
  }
});
