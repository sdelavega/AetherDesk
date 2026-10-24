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

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { loadWeatherAether } from './harness.mjs';

test('both wallpaper pages version every local script and link for v1.4', () => {
  for (const wallpaper of ['WeatherAether', 'NeonCity']) {
    const html = readFileSync(new URL(`../../Resources/Wallpapers/${wallpaper}/index.html`, import.meta.url), 'utf8');
    const assets = [...html.matchAll(/<(?:script|link)\b[^>]*\b(?:src|href)="([^"]+)"/g)].map(match => match[1]);
    assert.ok(assets.length > 0);
    for (const asset of assets) {
      if (/^(?:[a-z]+:|\/\/)/i.test(asset)) continue;
      assert.equal(new URL(asset, 'https://wallpaper.invalid/').search, '?v=1.4.0', `${wallpaper}: ${asset}`);
    }
  }
});

test('WeatherAether has a dark CSS body background before any script runs', () => {
  const html = readFileSync(new URL('../../Resources/Wallpapers/WeatherAether/index.html', import.meta.url), 'utf8');
  assert.match(html, /body\s*\{[^}]*background:\s*#071122\b/);
});

function fixture({ canvas2d = true, webgl = true, failInit = false, search = '' } = {}) {
  const events = new Map();
  const counts = { sky: 0, particles: 0, native: [], warnings: [], previews: [] };
  const gradient = { addColorStop() {} };
  const ctx = new Proxy({ createLinearGradient: () => gradient, createRadialGradient: () => gradient }, {
    get: (target, key) => target[key] ?? (() => {})
  });
  const container = { style: {} };
  const sky = { style: {}, parentElement: container, getContext: () => canvas2d ? ctx : null };
  const glCanvas = { style: {}, addEventListener: (name, callback) => events.set(name, callback) };
  class Vector {
    set() { return this; }
    copy() { return this; }
  }
  class Scene { add() {} remove() {} }
  class Geometry { setAttribute() {} setDrawRange() {} dispose() {} }
  class Material { constructor(options) { Object.assign(this, options); } dispose() {} }
  class Mesh {
    constructor(geometry, material) { Object.assign(this, { geometry, material, position: new Vector(), rotation: {}, scale: new Vector() }); }
  }
  class Camera { constructor() { this.position = new Vector(); } updateProjectionMatrix() {} }
  class Renderer {
    constructor() {
      if (failInit) throw new Error('no GPU');
      this.debug = {}; this.domElement = glCanvas;
    }
    setPixelRatio() {} getPixelRatio() { return 1; } setSize() {}
    getDrawingBufferSize() { return { x: 800, y: 600 }; }
    setRenderTarget() {} render() {}
    readRenderTargetPixels(target, x, y, width, height, pixels) {
      for (let i = 0; i < pixels.length; i += 4) { pixels[i] = i / 4; pixels[i + 3] = 255; }
    }
  }
  let initialProperties;
  const c = loadWeatherAether([
    'js/main.js', 'js/atmosphere.js', 'js/three-renderer.js',
    'js/renderer.js', 'js/static-fallback.js', 'js/weather.js', 'js/ui.js', 'js/bootstrap.js'
  ], {
    URLSearchParams, performance: { now: () => 100 }, requestAnimationFrame: () => 1,
    cancelAnimationFrame() {},
    setTimeout: callback => { callback(); return 1; },
    console: { warn: (...args) => counts.warnings.push(args), error() {} },
    document: {
      readyState: 'loading', hidden: false, addEventListener: (name, callback) => events.set(name, callback),
      getElementById: id => id === 'wa-sky' ? sky : id === 'wa-webgl' ? glCanvas : null
    },
    window: {
      innerWidth: 800, innerHeight: 600, devicePixelRatio: 1, location: { search }, addEventListener() {},
      parent: { postMessage: status => counts.previews.push(status) },
      webkit: { messageHandlers: { aetherDesk: { postMessage: message => counts.native.push(message) } } },
      aetherDesk: { properties: { onUpdate: callback => { initialProperties = callback; } } },
      WeatherAetherThree: webgl ? {
        WebGLRenderer: Renderer, Scene, PerspectiveCamera: Camera, ShaderMaterial: Material,
        Color: Vector, Vector2: Vector, Vector3: Vector, PlaneGeometry: Geometry,
        Mesh, Points: Mesh, BufferGeometry: Geometry, Float32BufferAttribute: class {},
        WebGLRenderTarget: class { constructor() { this.texture = {}; } setSize() {} dispose() {} }
      } : undefined
    }
  });
  c.drawAtmosphericSky = () => counts.sky++;
  c.drawBgCelestial = () => {};
  c.updateParticles = () => {};
  c.drawParticles = () => counts.particles++;
  c.setupAttribution = c.renderFallbackUI = c.showPill = () => {};
  c.loadCachedLocation = c.loadCachedWeather = () => null;
  c.resolveLocation = () => ({ then() {} });
  c.init();
  return { c, counts, sky, glCanvas, events, container, update: props => initialProperties(props) };
}

test('selectRenderer covers the preference and capability truth table', () => {
  const { c } = fixture();
  for (const rendererPref of ['auto', 'classic']) {
    for (const webgl of [false, true]) {
      for (const canvas2d of [false, true]) {
        const expected = !canvas2d ? 'static' : rendererPref === 'auto' && webgl ? 'three' : 'canvas';
        assert.equal(c.selectRenderer({ rendererPref, webgl, canvas2d }), expected);
      }
    }
  }
});

for (const trigger of ['context loss', 'shader error']) {
  test(`${trigger} demotes once on the next tick and restores Canvas particles`, () => {
    const { c, counts, events, glCanvas } = fixture();
    c.S.weatherBucket = 'rain';
    c.S.atmosphere = c.deriveAtmosphericState(null);
    c.S.atmosphere.condition = 'rain';
    c.S.atmosphere.precipitationIntensity = 0.7;
    assert.equal(c.S.useThreeRenderer, true);
    let demotions = 0;
    const demote = c.demoteRenderer;
    c.demoteRenderer = (origin, reason) => { demotions++; assert.equal(origin, 'three'); demote(origin, reason); };
    if (trigger === 'context loss') {
      let prevented = 0;
      const event = { preventDefault: () => prevented++ };
      events.get('webglcontextlost')(event);
      events.get('webglcontextlost')(event);
      assert.equal(prevented, 2);
    } else {
      c.S.threeAtmosphere.renderer.debug.onShaderError({
        getProgramInfoLog: () => 'link failed', getShaderInfoLog: () => 'compile failed'
      }, {}, {}, {});
    }
    assert.equal(c.S.useThreeRenderer, true);
    c.render(100);
    c.render(116);
    assert.equal(demotions, 1);
    assert.equal(c.S.useThreeRenderer, false);
    assert.equal(glCanvas.style.display, 'none');
    assert.equal(counts.sky, 2);
    assert.ok(c.S.particles.length > 0);
    assert.equal(counts.previews.at(-1).renderer, 'canvas');
  });
}

test('missing Canvas 2D applies a visible static gradient through boot and resize', () => {
  const { c, container, counts, sky } = fixture({ canvas2d: false });
  c.render(100);
  c.resizeCanvas();
  assert.equal(c.S.useThreeRenderer, false);
  assert.equal(sky.style.display, 'none');
  assert.match(container.style.background, /^linear-gradient\(/);
  assert.equal(counts.sky, 0);
  assert.equal(counts.particles, 0);
  assert.equal(counts.previews.at(-1).renderer, 'static');
});

test('both property bridges switch Classic and Auto without reloading or losing Canvas', () => {
  const { c, update, glCanvas } = fixture();
  const ctx = c.S.ctx;
  const three = c.S.threeAtmosphere;
  update({ renderer: 'classic' });
  c.render(100);
  assert.equal(c.S.useThreeRenderer, false);
  assert.equal(glCanvas.style.display, 'none');
  c.livelyPropertyListener('renderer', 'auto');
  assert.equal(c.S.useThreeRenderer, true);
  assert.equal(c.S.ctx, ctx);
  assert.equal(c.S.threeAtmosphere, three);
  update({ renderer: 'classic' });
  c.livelyPropertyListener('renderer', 'auto');
  assert.equal(c.S.threeAtmosphere, three);
});

test('initialization failure reports the Canvas fallback once', () => {
  const { counts } = fixture({ failInit: true });
  assert.equal(counts.previews.length, 1);
  assert.equal(counts.previews[0].renderer, 'canvas');
});

test('native logging failures warn and retry the same status', () => {
  const { c, counts } = fixture({ webgl: false });
  c.reportWeatherRendererStatus.lastNativeStatus = undefined;
  c.webkit.messageHandlers.aetherDesk.postMessage = () => { throw new Error('bridge unavailable'); };
  c.reportWeatherRendererStatus();
  assert.equal(counts.warnings.length, 1);
  let retries = 0;
  c.webkit.messageHandlers.aetherDesk.postMessage = () => retries++;
  c.reportWeatherRendererStatus();
  c.reportWeatherRendererStatus();
  assert.equal(retries, 1);
});

test('context loss while Classic is selected keeps Canvas rendering', () => {
  const { c, events, update, counts } = fixture();
  update({ renderer: 'classic' });
  events.get('webglcontextlost')({ preventDefault() {} });
  c.render(100);
  assert.equal(counts.previews.at(-1).renderer, 'canvas');
  assert.equal(counts.sky, 1);
});

test('a property switch between GPU failure and the next frame keeps Canvas rendering', () => {
  const { c, events, update, counts } = fixture();
  events.get('webglcontextlost')({ preventDefault() {} });
  update({ renderer: 'classic' });
  c.render(100);
  assert.equal(counts.previews.at(-1).renderer, 'canvas');
  assert.equal(counts.sky, 1);
});

test('Canvas overlay failure during Three rendering reaches static and stays there', () => {
  const { c, counts, update } = fixture();
  c.renderThreeAtmosphere = () => true;
  c.renderThreePresentation = () => {};
  c.drawBgCelestial = () => { throw new Error('2D drawing failed'); };
  c.render(100);
  assert.equal(counts.previews.at(-1).renderer, 'static');
  update({ renderer: 'classic' });
  assert.equal(counts.previews.at(-1).renderer, 'static');
});

test('static mode idles without style writes across ticks and updates on weather and resize', () => {
  const { c, container } = fixture({ canvas2d: false });
  let writes = 0, frames = 0;
  let background = container.style.background;
  Object.defineProperty(container.style, 'background', {
    get: () => background, set: value => { writes++; background = value; }
  });
  c.requestAnimationFrame = () => { frames++; return 2; };
  assert.equal(c.S.animationFrameId, null);
  c.render(100);
  c.render(116);
  c.applyRendererPreference();
  assert.equal(writes, 0);
  assert.equal(frames, 0);
  assert.equal(c.S.animationFrameId, null);
  c.renderUI = () => {};
  c.getPhaseColors = () => ({ top: [1, 2, 3], mid: [4, 5, 6], bot: [7, 8, 9] });
  c.applyWeather({ current: { weather_code: 0, is_day: 1 }, daily: {} });
  assert.equal(writes, 1);
  assert.ok(background.includes('rgb(1,2,3)'));
  c.resizeCanvas();
  assert.equal(writes, 2);
  assert.equal(frames, 0);
});

test('static demotion cancels the queued frame and renderer recovery resumes one loop', () => {
  const { c, update } = fixture({ webgl: false });
  const ctx = c.S.ctx;
  let cancelled = 0, frames = 0;
  c.cancelAnimationFrame = () => cancelled++;
  c.requestAnimationFrame = () => { frames++; return 2; };
  c.demoteRenderer('canvas', 'failed');
  assert.equal(cancelled, 1);
  assert.equal(c.S.animationFrameId, null);
  c.S.ctx = ctx;
  update({ renderer: 'classic' });
  assert.equal(c.S.renderer, 'canvas');
  assert.equal(frames, 1);
  c.applyRendererPreference();
  assert.equal(frames, 1);
});

test('visibility changes leave static idle and resume animated renderers once', () => {
  const { c, events } = fixture({ canvas2d: false });
  let frames = 0;
  c.requestAnimationFrame = () => { frames++; return 2; };
  c.document.hidden = true;
  events.get('visibilitychange')();
  c.document.hidden = false;
  events.get('visibilitychange')();
  assert.equal(frames, 0);
  c.S.renderer = 'canvas';
  events.get('visibilitychange')();
  events.get('visibilitychange')();
  assert.equal(frames, 1);
});

test('Canvas clear failure has Canvas origin even while Three is active', () => {
  const { c } = fixture();
  c.S.ctx.clearRect = () => { throw new Error('clear failed'); };
  c.render(100);
  assert.equal(c.S.renderer, 'static');
  assert.equal(c.S.rendererFailureReason, 'clear failed');
  assert.equal(c.S.useThreeRenderer, false);
});

test('explicit origin controls demotion regardless of reason text', () => {
  const { c } = fixture();
  c.demoteRenderer('three', 'Canvas: arbitrary GPU diagnostic');
  assert.equal(c.S.renderer, 'canvas');
  assert.ok(c.S.ctx);
  c.demoteRenderer('canvas', 'Canvas: arbitrary GPU diagnostic');
  assert.equal(c.S.renderer, 'static');
  assert.equal(c.S.ctx, null);
});

test('demotion is idempotent and a subsequent Canvas failure reaches static', () => {
  const { c, counts, container } = fixture();
  c.demoteRenderer('three', 'GPU failed');
  const reports = counts.previews.length;
  c.demoteRenderer('three', 'GPU failed');
  assert.equal(counts.previews.length, reports);
  assert.equal(c.S.useThreeRenderer, false);
  c.demoteRenderer('canvas', 'Canvas failed');
  assert.match(container.style.background, /^linear-gradient\(/);
  assert.equal(counts.previews.at(-1).renderer, 'static');
});
