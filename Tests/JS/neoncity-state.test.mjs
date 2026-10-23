// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Stephen de la Vega
// See Resources/Wallpapers/NeonCity/LICENSE.txt for the MIT license.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import { createHash } from 'node:crypto';

const root = new URL('../../Resources/Wallpapers/NeonCity/', import.meta.url);

// Record Canvas calls and paint settings without requiring an awake display.
function classicHarness() {
  const trace = [];
  const frames = [];
  const timers = [];
  let canvasID = 0, gradientID = 0;
  const canvas = () => {
    const id = `canvas${canvasID++}`;
    const context = new Proxy({}, {
      get(target, key) {
        if (key in target) return target[key];
        return (...args) => {
          trace.push([id, key, ...args.map(arg => arg?.traceID ?? arg)]);
          if (key === 'createLinearGradient' || key === 'createRadialGradient') {
            const traceID = `gradient${gradientID++}`;
            return { traceID, addColorStop: (...stops) => trace.push([traceID, ...stops]) };
          }
        };
      },
      set(target, key, value) { trace.push([id, key, value?.traceID ?? value]); target[key] = value; return true; }
    });
    return { traceID: id, getContext: () => context };
  };
  const output = canvas();
  const now = local(12);
  class Clock extends Date { constructor(...args) { super(...(args.length ? args : [now])); } }
  return { trace, frames, timers, now, stubs: {
    Date: Clock, screen: { width: 1920, height: 1080 },
    performance: { timeOrigin: 1234567890 }, innerWidth: 1920, innerHeight: 1080,
    document: { getElementById: () => output, createElement: canvas },
    addEventListener() {}, requestAnimationFrame: callback => frames.push(callback),
    setInterval: callback => timers.push(callback)
  } };
}

const traceDigest = trace => createHash('sha256').update(JSON.stringify(trace)).digest('hex');
function loadCity(files = ['js/city-state.js'], stubs = {}) {
  const context = vm.createContext({ ...stubs });
  context.window = context;
  for (const file of files) {
    vm.runInContext(readFileSync(new URL(file, root), 'utf8'), context, { filename: file });
  }
  return context;
}
const local = (hour, minute = 0) => new Date(2026, 0, 12, hour, minute);
function state(context, now, overrides = {}) {
  return context.deriveCityState({ now, timeMode: 'live', weatherMode: 'fixed',
    fixed: { rain: 60, fog: 30 }, live: null, seed: 42, ...overrides });
}

test('local phase boundaries and Always night', () => {
  const context = loadCity();
  for (const [hour, minute, expected] of [[4,59,'night'],[5,0,'dawn'],[6,59,'dawn'],
    [7,0,'day'],[17,59,'day'],[18,0,'dusk'],[20,59,'dusk'],[21,0,'night']]) {
    assert.equal(state(context, local(hour, minute)).phase, expected);
  }
  const pinned = state(context, local(12), { timeMode: 'night' });
  assert.equal(pinned.phase, 'night');
  assert.deepEqual(pinned, state(context, local(3)));
});

test('fixed slider normalization and bounded state values', () => {
  const context = loadCity();
  const result = state(context, local(3));
  assert.equal(result.rain, 0.5);
  assert.equal(result.fog, 0.3);
  for (let hour = 0; hour < 24; hour++) {
    const result = state(context, local(hour));
    for (const key of ['phaseBlend','rain','fog','neon','windowsLit','trafficDensity']) {
      assert.ok(result[key] >= 0 && result[key] <= 1, `${key} at ${hour}`);
    }
  }
});

test('windows thin monotonically from 21:00 through 04:00', () => {
  const context = loadCity();
  let previous = 1;
  let first;
  for (let minute = 0; minute <= 7 * 60; minute++) {
    const now = new Date(2026, 0, 12, 21, minute);
    const value = state(context, now).windowsLit;
    first ??= value;
    assert.ok(value <= previous);
    previous = value;
  }
  assert.ok(previous < first);
});

test('drifting is deterministic and holds each state for at least 20 minutes', () => {
  const context = loadCity();
  const start = local(0).getTime();
  let previous, changedAt;
  let changes = 0;
  for (let minute = 0; minute < 3 * 24 * 60; minute++) {
    const now = new Date(start + minute * 60000);
    const weather = context.driftingWeather(42, now);
    assert.deepEqual(weather, context.driftingWeather(42, now));
    if (previous && weather.state !== previous) {
      if (changedAt !== undefined) assert.ok(minute - changedAt >= 20);
      changedAt = minute;
      changes++;
    }
    previous = weather.state;
  }
  assert.ok(changes > 10);
});

test('rain and fog blend over at least three minutes without second-wise steps', () => {
  const context = loadCity();
  const start = local(0).getTime();
  let previous = context.driftingWeather(42, new Date(start));
  let blendStart, changedSeconds = 0, blends = 0;
  for (let second = 1; second <= 4 * 3600; second++) {
    const weather = context.driftingWeather(42, new Date(start + second * 1000));
    const delta = Math.max(Math.abs(weather.rain - previous.rain), Math.abs(weather.fog - previous.fog));
    assert.ok(delta <= 0.05, `step ${delta} at ${second}`);
    if (delta > 1e-10) {
      blendStart ??= second;
      changedSeconds++;
    } else if (blendStart !== undefined) {
      assert.ok(changedSeconds >= 180, `blend lasted ${changedSeconds} seconds`);
      blends++;
      blendStart = undefined;
      changedSeconds = 0;
    }
    previous = weather;
  }
  assert.ok(blends > 0);
});

test('snow is winter-only and rare across 10000 seeded draws', () => {
  const context = loadCity();
  let januarySnow = 0;
  for (let seed = 0; seed < 10000; seed++) {
    assert.notEqual(context.driftingWeather(seed, new Date(2026, 5, 15, 12)).state, 'snow');
    if (context.driftingWeather(seed, new Date(2026, 0, 15, 12)).state === 'snow') januarySnow++;
  }
  assert.ok(januarySnow > 0);
  assert.ok(januarySnow <= 1000);
});

test('live consumes provided conditions and falls back deterministically when absent', () => {
  const context = loadCity();
  const snow = state(context, local(12), { weatherMode: 'live', live: { state: 'snow', intensity: 0.8 } });
  assert.equal(snow.weather, 'snow');
  assert.equal(snow.rain, 0);
  const rain = state(context, local(12), { weatherMode: 'live', live: { state: 'rain', intensity: 0.7 } });
  assert.equal(rain.rain, 0.7);
  assert.deepEqual(state(context, local(12), { weatherMode: 'live' }),
    state(context, local(12), { weatherMode: 'drifting' }));
});

test('Classic matches the original Fixed + Always night drawing trace', () => {
  const harness = classicHarness();
  const context = loadCity(['js/city-state.js', 'js/classic-renderer.js'], harness.stubs);
  context.ClassicCityRenderer.start(state(context, local(12), { timeMode: 'night' }),
    { neonBrightness: 100, vehicleCount: 8 });
  for (let frame = 0; frame < 12; frame++) harness.frames.shift()(1000 + frame * 1000 / 30);
  // Captured from the original inline scene, with identical dimensions, RNG
  // timeOrigin and frame timestamps; includes calls AND every paint setting.
  assert.equal(harness.trace.length, 14627);
  assert.equal(traceDigest(harness.trace), 'f00b69008dbae743c04bc12b1c11f2156209d83037501ceb10df3db155b1f440');
});

test('property routing, defaults, refresh cadence and Live input reach the renderer', () => {
  const calls = [], timers = [];
  const context = loadCity(['js/city-state.js', 'js/main.js'], {
    screen: { width: 1920, height: 1080 },
    ClassicCityRenderer: { applyState: (state, props) => calls.push({ state, props: { ...props } }),
      start: (state, props) => calls.push({ state, props: { ...props } }) },
    setInterval: (callback, delay) => timers.push({ callback, delay })
  });
  assert.equal(calls.at(-1).props.timeMode, 'live');
  assert.equal(calls.at(-1).props.weatherMode, 'drifting');
  assert.equal(calls.at(-1).props.renderer, 'auto');
  assert.equal(timers.length, 1);
  assert.equal(timers[0].delay, 1000);
  context.livelyPropertyListener('timeMode', 1);
  context.livelyPropertyListener('weatherMode', 2);
  assert.equal(calls.at(-1).state.phase, 'night');
  assert.equal(calls.at(-1).state.rain, 0.5);
  assert.equal(calls.at(-1).state.fog, 0.3);
  context.livelyPropertyListener('rainIntensity', 120);
  assert.equal(calls.at(-1).state.rain, 1);
  context.livelyPropertyListener('weatherMode', 'Live');
  context.setCityLiveWeather({ state: 'downpour', intensity: 0.9 });
  assert.equal(calls.at(-1).state.weather, 'downpour');
  assert.equal(calls.at(-1).state.rain, 0.9);
  context.livelyPropertyListener('timeMode', 'Always night');
  context.livelyPropertyListener('renderer', 'Classic');
  context.livelyPropertyListener('locationMode', 1);
  context.livelyPropertyListener('manualLocation', 'Seattle');
  assert.equal(calls.at(-1).props.renderer, 'classic');
  assert.equal(calls.at(-1).props.locationMode, 'manual');
  assert.equal(calls.at(-1).props.manualLocation, 'Seattle');
  const count = calls.length;
  timers[0].callback();
  assert.equal(calls.length, count + 1);
});

test('Classic state changes preserve city geometry and avoid redundant redraws', () => {
  const harness = classicHarness();
  const context = loadCity(['js/city-state.js', 'js/classic-renderer.js'], harness.stubs);
  const night = state(context, local(3));
  const properties = { neonBrightness: 100, vehicleCount: 8 };
  context.ClassicCityRenderer.start(night, properties);
  const geometry = harness.trace.filter(row => row[0] === 'canvas1' && ['arc','lineTo','fillRect'].includes(row[1]));
  const count = harness.trace.length;
  context.ClassicCityRenderer.applyState(night, properties);
  assert.equal(harness.trace.length, count);
  harness.trace.length = 0;
  context.ClassicCityRenderer.applyState({ ...night, neon: 0.7 }, properties);
  assert.deepEqual(harness.trace.filter(row => row[0] === 'canvas1' && ['arc','lineTo','fillRect'].includes(row[1])), geometry);
  harness.trace.length = 0;
  context.ClassicCityRenderer.applyState({ ...night, rain: 0, fog: 0, trafficDensity: 0, neon: 0.7 }, properties);
  harness.frames.shift()(1000);
  assert.equal(harness.trace.filter(row => row[0] === 'canvas0' && row[1] === 'drawImage').length, 4);
  const rainPath = harness.trace.findIndex(row => row[0] === 'canvas0' && row[1] === 'strokeStyle' && row[2] === 'rgba(155,200,238,0.22)');
  assert.equal(harness.trace[rainPath + 3][1], 'stroke');
});

test('Lively properties retain the object format and requested dropdown defaults', () => {
  const properties = JSON.parse(readFileSync(new URL('LivelyProperties.json', root), 'utf8'));
  assert.ok(!Array.isArray(properties));
  for (const [name, items] of Object.entries({ timeMode: ['Live','Always night'],
    weatherMode: ['Drifting','Live','Fixed'], renderer: ['Auto','Classic'], locationMode: ['auto','manual'] })) {
    assert.deepEqual(properties[name].items, items);
    assert.equal(properties[name].value, 0);
  }
  assert.equal(properties.vehicleCount.text, 'Traffic Density');
  assert.equal(properties.manualLocation.value, '');
});
