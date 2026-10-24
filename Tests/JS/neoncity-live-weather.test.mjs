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
import vm from 'node:vm';

const root = new URL('../../Resources/Wallpapers/', import.meta.url);
const plain = value => JSON.parse(JSON.stringify(value));
const settle = async () => { for (let i = 0; i < 30; i++) await Promise.resolve(); };
function city({ host, geolocation, cached, fail = false } = {}) {
  const requests = [], frames = [], timers = new Map(), elements = new Map();
  let id = 0, failing = fail;
  const storage = new Map(cached ? [['wa.lastLoc', JSON.stringify(cached)]] : []);
  elements.set('c', { style: {} }); elements.set('city-webgl', { style: {} });
  const context = vm.createContext({ URL, URLSearchParams, AbortSignal, console, Date,
    location: { search: '?renderer=classic' }, requestAnimationFrame() {},
    screen: { width: 1920, height: 1080 }, navigator: { geolocation }, aetherDesk: host,
    localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, val) => storage.set(key, val) },
    document: { getElementById: key => elements.get(key), body: { style: {}, appendChild: el => elements.set(el.id, el) },
      createElement: () => ({ style: {}, textContent: '', hidden: false, setAttribute() {} }) },
    setTimeout: (fn, ms) => { timers.set(++id, { fn, ms }); return id; },
    clearTimeout: key => timers.delete(key), setInterval() {},
    ClassicCityRenderer: { start: state => frames.push(plain(state)), applyState: state => frames.push(plain(state)) },
    fetch: async url => {
      requests.push(String(url));
      if (failing) throw new Error('Network policy denied');
      return { ok: true, headers: { get: () => null }, json: async () =>
        String(url).includes('ipapi.co') ? { latitude: 1, longitude: 2 } :
        String(url).includes('bigdatacloud') ? { city: 'City' } :
        String(url).includes('/search') ? { results: [{ latitude: 1, longitude: 2, name: 'City' }] } :
        { current: { weather_code: 65, precipitation: 7 } } };
    }
  });
  context.window = context;
  // Use the actual page's script order; the renderer is replaced with a frame observer.
  const html = readFileSync(new URL('NeonCity/index.html', root), 'utf8');
  for (const [, file] of html.matchAll(/<script src="([^"]+)"/g)) {
    if (file.split('?')[0].endsWith('classic-renderer.js')) continue;
    vm.runInContext(readFileSync(new URL(`NeonCity/${file}`, root), 'utf8'), context, { filename: file });
  }
  // Observe the atmosphere delivered to the frame dispatcher; rendering itself
  // is covered by neoncity-fallback and the Classic drawing-trace tests.
  const refresh = context.refreshCityState;
  context.refreshCityState = () => { const state = refresh(); frames.push(plain(state)); return state; };
  context.refreshCityState();
  return { context, requests, frames, timers, elements, fail: (value = true) => { failing = value; } };
}

const groups = { clear: [0, 1, 2, 3], fog: [4, 5, 6, 7, 45, 48], drizzle: [51, 53, 55],
  rain: [56, 57, 61, 63, 66, 67, 80, 81], downpour: [65, 82, 95, 96, 99], snow: [71, 73, 75, 77, 85, 86] };
test('mapping covers every WMO_DESC code and bounds precipitation intensity', () => {
  const { context } = city();
  const source = vm.createContext({});
  vm.runInContext(readFileSync(new URL('WeatherAether/js/atmosphere.js', root), 'utf8'), source);
  assert.deepEqual(Object.values(groups).flat().sort((a, b) => a - b), Object.keys(source.WMO_DESC).map(Number).sort((a, b) => a - b));
  for (const [state, codes] of Object.entries(groups)) for (const code of codes) {
    for (const precip of [undefined, NaN, -1, 0, 0.5, 10, Infinity]) {
      const mapped = context.mapWmoToCityWeather(code, precip);
      assert.equal(mapped.state, state, `WMO ${code}`);
      assert.ok(Number.isFinite(mapped.intensity) && mapped.intensity >= 0 && mapped.intensity <= 1);
    }
  }
  assert.ok(context.mapWmoToCityWeather(63, 5).intensity > context.mapWmoToCityWeather(63, 0.5).intensity);
  assert.equal(context.mapWmoToCityWeather(999, 1).state, 'clear');
});

const denied = { getCurrentPosition(_ok, fail) { fail(); } };
const located = { getCurrentPosition(ok) { ok({ coords: { latitude: 1, longitude: 2 } }); } };
for (const host of [undefined, {}, { system: {} }, { system: { capabilities: {} } },
  { system: { capabilities: { ipGeolocation: false } } }]) {
  for (const geolocation of [undefined, denied, located]) test(`Live capability gate ${JSON.stringify(host)} / ${geolocation === located ? 'located' : geolocation ? 'denied' : 'absent'}`, async () => {
    const { context, requests } = city({ host, geolocation, cached: { lat: 1, lon: 2 } });
    assert.equal(requests.length, 0, 'Drifting does not fetch');
    context.livelyPropertyListener('weatherMode', 'live');
    await settle();
    assert.ok(requests.some(url => url.startsWith('https://api.open-meteo.com/')));
    assert.ok(requests.every(url => !/ipapi\.co|api\.bigdatacloud\.net/.test(url)));
  });
}
test('Live without device or cache gives a city notice and keeps drawing', async () => {
  const { context, requests, frames, elements } = city();
  context.livelyPropertyListener('weatherMode', 'live');
  await settle();
  assert.deepEqual(requests, []);
  assert.match(elements.get('city-weather-notice').textContent, /Set a city/);
  assert.ok(frames.length > 1 && frames.every(frame => frame.weather));
});
test('manual city and host-enabled IP/reverse geocoding use existing endpoints', async () => {
  for (const geolocation of [denied, located]) {
    const run = city({ host: { system: { capabilities: { ipGeolocation: true } } }, geolocation });
    run.context.livelyPropertyListener('weatherMode', 'live');
    await settle();
    assert.ok(run.requests.some(url => url.includes(geolocation === denied ? 'ipapi.co' : 'bigdatacloud.net')));
    assert.equal(run.frames.at(-1).weather, 'downpour');
  }
  const run = city();
  run.context.livelyPropertyListener('manualLocation', 'Paris');
  run.context.livelyPropertyListener('locationMode', 'manual');
  run.context.livelyPropertyListener('weatherMode', 'live');
  await settle();
  assert.ok(run.requests.some(url => url.startsWith('https://geocoding-api.open-meteo.com/')));
  assert.equal(run.frames.at(-1).weather, 'downpour');
});
test('Live network failure clears live data and draws Drifting without restarting renderer', async () => {
  const run = city({ geolocation: located });
  run.context.livelyPropertyListener('weatherMode', 'live');
  await settle();
  assert.equal(run.frames.at(-1).weather, 'downpour');
  run.fail();
  const retry = [...run.timers.values()].find(timer => timer.ms >= 600000);
  assert.ok(retry, 'periodic weather refresh scheduled');
  const count = run.frames.length;
  retry.fn();
  await settle();
  assert.ok(run.frames.length > count);
  const expected = vm.runInContext('deriveCityState({now:new Date(),timeMode:cityProperties.timeMode,weatherMode:"drifting",seed:cityWeatherSeed})', run.context);
  assert.equal(run.frames.at(-1).weather, expected.weather);
  assert.ok(run.frames.every(frame => typeof frame.rain === 'number' && frame.weather));
  assert.match(run.elements.get('city-weather-notice').textContent, /Drifting/);
});
test('initial network failure draws Drifting and a later retry recovers Live', async () => {
  const run = city({ geolocation: located, fail: true });
  run.context.livelyPropertyListener('weatherMode', 'live');
  await settle();
  assert.equal(vm.runInContext('cityLiveWeather', run.context), null);
  assert.ok(run.frames.every(frame => frame.weather));
  assert.match(run.elements.get('city-weather-notice').textContent, /Drifting/);
  run.fail(false);
  [...run.timers.values()].find(timer => timer.ms >= 600000).fn();
  await settle();
  assert.equal(run.frames.at(-1).weather, 'downpour');
  assert.equal(run.elements.get('city-weather-notice').hidden, true);
});
test('late device location after leaving Live cannot fetch or overwrite Fixed', async () => {
  let locate;
  const run = city({ geolocation: { getCurrentPosition(ok) { locate = ok; } } });
  run.context.livelyPropertyListener('weatherMode', 'live');
  run.context.livelyPropertyListener('weatherMode', 'fixed');
  locate({ coords: { latitude: 1, longitude: 2 } });
  await settle();
  assert.deepEqual(run.requests, []);
  assert.equal(run.frames.at(-1).rain, 0.5);
  assert.equal(vm.runInContext('cityLiveWeather', run.context), null);
});
test('leaving Live invalidates pending acquisition and cancels refresh', async () => {
  const run = city({ geolocation: located });
  run.context.livelyPropertyListener('weatherMode', 'live');
  run.context.livelyPropertyListener('weatherMode', 'fixed');
  await settle();
  assert.equal([...run.timers.values()].filter(timer => timer.ms >= 600000).length, 0);
});
