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

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const root = new URL('../../Resources/Wallpapers/NeonCity/', import.meta.url);
const source = path => readFileSync(new URL(path, root), 'utf8');
function runtime({ webgl = true, canvas = true, init = true, classicThrows = false } = {}) {
  const callbacks = [], listeners = {}, elements = {};
  let classicFrames = 0, threeFrames = 0;
  for (const id of ['c', 'city-webgl']) elements[id] = {
    style: {}, width: 1920, height: 1080,
    getContext: () => canvas ? {} : null,
    addEventListener: (name, fn) => { listeners[name] = fn; }
  };
  const context = vm.createContext({ console, URLSearchParams,
    screen: { width: 1920, height: 1080 }, innerWidth: 1920, innerHeight: 1080,
    devicePixelRatio: 1, performance: { now: () => 0 },
    document: { body: { style: {} }, getElementById: id => elements[id] },
    location: { search: '' }, setInterval() {},
    requestAnimationFrame: fn => { callbacks.push(fn); },
    addEventListener() {},
    aetherDesk: { system: { qualityMode: 'balanced' } },
    ClassicCityRenderer: canvas ? { draw() { if (classicThrows) throw Error('canvas failed'); classicFrames++; } } : null,
    NeonCityThree: webgl ? {} : null,
    createNeonCityWeather: () => ({ configure() {} })
  });
  context.window = context;
  vm.runInContext(source('js/city-state.js'), context);
  vm.runInContext(source('js/three-city.js'), context);
  vm.runInContext(source('js/static-fallback.js'), context);
  vm.runInContext(`initializeThreeCity = function(canvas) {
    canvas.addEventListener('webglcontextlost', function(e) { e.preventDefault(); demoteRenderer('three', 'context lost'); });
    return ${init};
  }; renderThreeCity = function() { window.threeFrame(); };`, context);
  context.threeFrame = () => { threeFrames++; };
  return { context, elements, listeners, callbacks,
    run: code => vm.runInContext(code, context),
    start() { vm.runInContext(source('js/main.js'), context); },
    tick(t) { const fn = callbacks.shift(); assert.ok(fn, 'frame scheduled'); fn(t); },
    counts: () => ({ classicFrames, threeFrames }) };
}

test('actual page scripts draw Classic and a static gradient with three-city.js missing', () => {
  for (const canvasAvailable of [true, false]) {
    const callbacks = [], elements = {}; let blits = 0;
    const gradient = { addColorStop() {} };
    const drawing = new Proxy({}, { get(target, key) {
      if (key in target) return target[key];
      if (key === 'createLinearGradient' || key === 'createRadialGradient') return () => gradient;
      if (key === 'measureText') return () => ({ width: 32 });
      if (key === 'drawImage') return () => { blits++; };
      return () => {};
    } });
    const canvas = () => ({ style: {}, getContext: () => canvasAvailable ? drawing : null, addEventListener() {} });
    elements.c = canvas(); elements['city-webgl'] = canvas();
    const context = vm.createContext({ console, URLSearchParams, AbortSignal,
      screen: { width: 640, height: 360 }, innerWidth: 640, innerHeight: 360,
      performance: { now: () => 0, timeOrigin: 1000 }, location: { search: '' },
      navigator: {}, document: { body: { style: {} }, createElement: canvas, getElementById: id => elements[id] },
      setInterval() {}, setTimeout() {}, clearTimeout() {}, addEventListener() {},
      requestAnimationFrame: fn => callbacks.push(fn)
    });
    context.window = context;
    for (const [, file] of source('index.html').matchAll(/<script src="([^"]+)"/g)) {
      if (file.split('?')[0] === 'js/three-city.js') continue;
      vm.runInContext(source(file), context, { filename: file });
    }
    assert.equal(context.NeonCityStatus.renderer, canvasAvailable ? 'canvas' : 'static');
    const before = blits;
    callbacks.shift()(0);
    if (canvasAvailable) {
      assert.ok(blits > before, 'production Classic composites a frame');
      assert.equal(context.NeonCityStatus.lastPaint, 0);
    } else assert.match(context.document.body.style.background, /linear-gradient/);
  }
});

test('seeded CityModel has stable footprints/heights and all depth bands', () => {
  const r = runtime();
  const first = r.run('JSON.stringify(buildCity(7319))');
  assert.equal(first, r.run('JSON.stringify(buildCity(7319))'));
  assert.notEqual(first, r.run('JSON.stringify(buildCity(7320))'));
  const model = JSON.parse(first);
  for (const band of ['near', 'mid', 'far']) {
    const towers = model.towers.filter(tower => tower.band === band);
    assert.ok(towers.length > 0);
    assert.ok(towers.every(tower => tower.w > 0 && tower.h > 0 && tower.d > 0));
  }
});

test('renderer selection matches WeatherAether truth table', () => {
  const r = runtime();
  for (const rendererPref of ['auto', 'classic']) for (const webgl of [false, true]) for (const canvas2d of [false, true]) {
    r.context.env = { rendererPref, webgl, canvas2d };
    assert.equal(r.run('selectRenderer(env)'), !canvas2d ? 'static' : rendererPref !== 'classic' && webgl ? 'three' : 'canvas');
  }
});

test('quality tier table accounts for eco, battery, and Low Power Mode independently', () => {
  const r = runtime();
  for (const qualityMode of ['balanced', 'eco']) for (const onBattery of [false, true]) for (const isLowPowerMode of [false, true]) {
    r.context.system = { qualityMode, onBattery, isLowPowerMode };
    assert.deepEqual(JSON.parse(r.run('JSON.stringify(qualityTier(system))')),
      qualityMode === 'eco' || onBattery || isLowPowerMode ?
        { fps: 15, renderScale: 0.5, countScale: 0.4, eventScale: 0.5 } :
        { fps: 30, renderScale: 0.75, countScale: 1, eventScale: 1 });
  }
});

test('host callback jitter retains the normal and saver paint cadence', () => {
  for (const [qualityMode, expected] of [['balanced', 30], ['eco', 15]]) for (const steps of [[16], [32], [33.2], [33, 33, 34], [32, 34, 34]]) {
    const r = runtime(); r.context.aetherDesk.system.qualityMode = qualityMode; r.start();
    // Cover both early callbacks and WebKit's quantized 30 Hz timestamps.
    for (let t = 0, i = 0; t < 60000; t += steps[i++ % steps.length]) r.tick(t);
    const fps = r.counts().threeFrames / 60;
    assert.ok(Math.abs(fps - expected) < .05, `${qualityMode}, ${steps.join('/')} ms callbacks: ${fps} fps`);
  }
});

test('context loss draws Classic on the next frame, without retrying WebGL', () => {
  const r = runtime(); r.start(); r.tick(0);
  assert.equal(r.counts().threeFrames, 1);
  let prevented = false;
  r.listeners.webglcontextlost({ preventDefault() { prevented = true; } });
  r.tick(40);
  assert.ok(prevented);
  assert.equal(r.counts().classicFrames, 1);
  assert.equal(r.counts().threeFrames, 1);
  assert.equal(r.elements['city-webgl'].style.display, 'none');
  r.run("livelyPropertyListener('renderer','auto')"); r.tick(80);
  assert.equal(r.counts().threeFrames, 1);
});

test('initialization, render, and Canvas failures descend to a phase gradient', () => {
  const init = runtime({ init: false }); init.start(); init.tick(0);
  assert.equal(init.counts().classicFrames, 1);
  const render = runtime(); render.start();
  render.context.threeFrame = () => { throw Error('shader failed'); };
  render.tick(0); render.tick(40);
  assert.equal(render.counts().classicFrames, 1);
  const failed = runtime({ webgl: false, classicThrows: true }); failed.start(); failed.tick(0);
  assert.equal(failed.context.NeonCityStatus.renderer, 'static');
  const gradients = new Set();
  for (const phase of ['night', 'dawn', 'day', 'dusk']) {
    failed.context.phase = phase;
    failed.run('applyStaticAtmosphere({phase})');
    assert.match(failed.context.document.body.style.background, /linear-gradient/);
    gradients.add(failed.context.document.body.style.background);
  }
  assert.equal(gradients.size, 4, 'all phase gradients are pairwise distinct');
});

test('tier changes apply live, cap cadence, and never recover above saver scale', () => {
  const r = runtime(); r.start(); r.tick(0);
  r.context.aetherDesk.system.onBattery = true;
  for (let t = 20; t <= 200; t += 20) r.tick(t);
  assert.equal(r.context.NeonCityStatus.tier.fps, 15);
  assert.ok(r.context.NeonCityStatus.renderScale <= .5);
  assert.ok(r.counts().threeFrames <= 4);
  r.context.aetherDesk.system.onBattery = false; r.tick(280);
  assert.equal(r.context.NeonCityStatus.tier.fps, 30);
});

test('adaptive scale respects strict frame-time and recovery boundaries', () => {
  const r = runtime();
  for (const [current, p95, duration, expected] of [
    [.75, 20, 0, .75], [.75, 20.1, 0, .6], [.6, 20.1, 0, .5], [.5, 20.1, 0, .5],
    [.5, 12, 60000, .5], [.5, 11.9, 59999, .5], [.5, 11.9, 60000, .6],
    [.6, 11.9, 60000, .75], [.75, 11.9, 60000, .75]
  ]) assert.equal(r.context.adaptRenderScale(current, p95, duration), expected);
});

test('measured ten-second p95 windows step down and recover after sixty continuous seconds', () => {
  const r = runtime(); let clock = 0, cost = 20.1;
  r.context.performance.now = () => clock;
  r.context.threeFrame = () => { clock += cost; };
  r.start(); r.tick(0); r.tick(9999);
  assert.equal(r.context.NeonCityStatus.renderScale, .75);
  r.tick(10040);
  assert.ok(Math.abs(r.context.NeonCityStatus.p95FrameMs - cost) < 1e-9);
  assert.equal(r.context.NeonCityStatus.renderScale, .6);
  r.tick(20040);
  assert.equal(r.context.NeonCityStatus.renderScale, .5);
  cost = 11.9;
  for (let t = 30040; t <= 70040; t += 10000) r.tick(t);
  assert.equal(r.context.NeonCityStatus.renderScale, .5);
  r.tick(80040);
  assert.equal(r.context.NeonCityStatus.renderScale, .6);
  for (let t = 90040; t <= 140040; t += 10000) r.tick(t);
  assert.equal(r.context.NeonCityStatus.renderScale, .75);
});

test('recovery resets on a slow window and never exceeds the tier ceiling', () => {
  const r = runtime(); let clock = 0, cost = 25;
  r.context.performance.now = () => clock;
  r.context.threeFrame = () => { clock += cost; };
  r.start(); r.tick(0); r.tick(10000); r.tick(20000);
  cost = 10;
  for (let t = 30000; t <= 70000; t += 10000) r.tick(t);
  cost = 12; r.tick(80000); r.tick(90000);
  cost = 10;
  for (let t = 100000; t <= 140000; t += 10000) r.tick(t);
  assert.equal(r.context.NeonCityStatus.renderScale, .5);
  r.tick(150000);
  assert.equal(r.context.NeonCityStatus.renderScale, .6);
  r.context.aetherDesk.system.onBattery = true;
  for (let t = 180000; t <= 280000; t += 10000) r.tick(t);
  assert.equal(r.context.NeonCityStatus.renderScale, .5);
  r.context.aetherDesk.system.onBattery = false; r.tick(290000);
  assert.equal(r.context.NeonCityStatus.renderScale, .75);
});

test('Traffic Density property changes Three-mode vehicle counts across both tiers', () => {
  const r = runtime();
  vm.runInContext(source('js/city-life.js'), r.context);
  r.run('window.testLife = createLife(7319, buildCity(7319))');
  r.context.threeFrame = () => r.run('testLife.update(0, currentCityState)');
  r.start(); r.run("livelyPropertyListener('timeMode', 'night')");
  let t = 0;
  for (const onBattery of [false, true]) {
    r.context.aetherDesk.system.onBattery = onBattery;
    for (const value of [8, 0, 20, 5, 8]) {
      r.run(`livelyPropertyListener('vehicleCount', ${value})`); r.tick(t += 100);
      assert.equal(r.context.NeonCityStatus.renderer, 'three');
      assert.equal(r.context.testLife.vehicles.length, Math.round((onBattery ? .4 : 1) * value));
      assert.ok(Array.from(r.context.testLife.vehicles).every(vehicle => vehicle && Number.isFinite(vehicle.t)));
    }
  }
});

test('production initializer wires context loss and shader failure, and disposes failed initialization', () => {
  const r = runtime();
  const failures = []; let disposed = false, renderer;
  r.context.demoteRenderer = (origin, reason) => failures.push({ origin, reason });
  r.context.NeonCityThree = {
    WebGLRenderer: class { constructor() { this.debug = {}; renderer = this; } dispose() { disposed = true; } }
  };
  // Restore the production initializer rather than the dispatcher's test double.
  const production = source('js/three-city.js').replace('let threeCity = null;', 'threeCity = null;')
    .replace('const CITY_PALETTES =', 'window.TestCityPalettes =');
  vm.runInContext(production, r.context);
  assert.equal(r.run("initializeThreeCity(document.getElementById('city-webgl'), buildCity(7319))"), false);
  assert.ok(disposed);
  r.listeners.webglcontextlost({ preventDefault() {} });
  renderer.debug.onShaderError();
  assert.deepEqual(failures.map(failure => failure.origin), ['three', 'three']);
  assert.match(failures[1].reason, /Shader/);
});

test('production scene uses direct instancing, a slow closed spline, and highp shaders', () => {
  const code = source('js/three-city.js');
  assert.doesNotMatch(code, /EffectComposer|RenderPass|UnrealBloomPass|postprocessing/);
  assert.match(code, /InstancedMesh/);
  assert.match(code, /CatmullRomCurve3/);
  assert.match(code, /600000/);
  assert.match(code, /precision:\s*'highp'/);
  assert.match(code, /onShaderError/);
  assert.match(code, /webglcontextlost/);
});
