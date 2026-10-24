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
import { loadWeatherAether } from './harness.mjs';

function locationContext({ host, geolocation, cached, manual = '', mode = 'auto' } = {}) {
  const requests = [];
  const notices = [];
  const timers = new Map();
  let timerID = 0;
  const context = loadWeatherAether(['js/weather.js'], {
    URL, AbortSignal,
    aetherDesk: host,
    navigator: geolocation ? { geolocation } : {},
    S: { props: { locationMode: mode, manualLocation: manual }, locSeq: 0 },
    setTimeout: callback => { timers.set(++timerID, callback); return timerID; },
    clearTimeout: id => timers.delete(id),
    showPill: message => notices.push(message),
    hidePill() {},
    fetch: async url => {
      requests.push(String(url));
      return { ok: true, json: async () => {
        if (String(url).includes('ipapi.co')) return { latitude: 35.2, longitude: -80.8, city: 'Charlotte', region_code: 'NC' };
        if (String(url).includes('bigdatacloud')) return { city: 'Charlotte', principalSubdivisionCode: 'NC' };
        return { results: [{ latitude: 48.85, longitude: 2.35, name: 'Paris', admin1: 'Île-de-France' }] };
      } };
    }
  });
  if (cached) context.localStorage.setItem('wa.lastLoc', JSON.stringify(cached));
  return { context, requests, notices, timers };
}

const denied = { getCurrentPosition(_success, failure) { failure(); } };
const located = { getCurrentPosition(success) { success({ coords: { latitude: 35.2271, longitude: -80.8431 } }); } };
const enabled = { system: { capabilities: { ipGeolocation: true } } };

for (const host of [undefined, {}, { system: {} }, { system: { capabilities: {} } },
  { system: { capabilities: { ipGeolocation: false } } }]) {
  test(`auto mode without capability uses cache without IP services: ${JSON.stringify(host)}`, async () => {
    let attempted = false;
    const geolocation = { getCurrentPosition(success, failure) { attempted = true; denied.getCurrentPosition(success, failure); } };
    const { context, requests } = locationContext({ host, geolocation,
      cached: { lat: 35.2271, lon: -80.8431, label: 'Old city label' } });
    assert.equal(await context.resolveLocation(), true);
    assert.equal(attempted, true);
    assert.equal(context.S.lat, 35.2271);
    assert.equal(context.S.lon, -80.8431);
    assert.match(context.S.label, /35\.23.*-80\.84/);
    assert.deepEqual(requests, []);
  });
}

test('without capability or cache auto mode shows settings notice, ignoring default manual city', async () => {
  const { context, requests, notices } = locationContext({ geolocation: denied, manual: 'Charlotte' });
  assert.equal(await context.resolveLocation(), false);
  assert.deepEqual(requests, []);
  assert.ok(notices.includes("Set a city in this wallpaper's settings"));
});

test('without navigator geolocation auto mode still avoids IP services', async () => {
  const { context, requests, notices } = locationContext();
  assert.equal(await context.resolveLocation(), false);
  assert.deepEqual(requests, []);
  assert.ok(notices.includes("Set a city in this wallpaper's settings"));
});

test('geolocation timeout without capability uses cache', async () => {
  const { context, requests, timers } = locationContext({
    geolocation: { getCurrentPosition() {} }, cached: { lat: 1, lon: 2, label: 'Old city' }
  });
  const resolution = context.resolveLocation();
  [...timers.values()][0]();
  assert.equal(await resolution, true);
  assert.deepEqual(requests, []);
});

test('device coordinates without capability do not reverse geocode', async () => {
  const { context, requests } = locationContext({ geolocation: located });
  assert.equal(await context.resolveLocation(), true);
  assert.match(context.S.label, /35\.23.*-80\.84/);
  assert.deepEqual(requests, []);
});

test('manual mode uses the Open-Meteo place name', async () => {
  const { context, requests } = locationContext({ mode: 'manual', manual: 'Paris' });
  assert.equal(await context.resolveLocation(), true);
  assert.equal(context.S.label, 'Paris, Île-de-France');
  assert.equal(requests.length, 1);
  assert.ok(requests[0].startsWith('https://geocoding-api.open-meteo.com/'));
});

test('host capability preserves IP fallback', async () => {
  const { context, requests } = locationContext({ host: enabled, geolocation: denied });
  assert.equal(await context.resolveLocation(), true);
  assert.equal(context.S.label, 'Charlotte, NC');
  assert.deepEqual(requests, ['https://ipapi.co/json/']);
});

test('host capability preserves BigDataCloud reverse geocoding', async () => {
  const { context, requests } = locationContext({ host: enabled, geolocation: located });
  assert.equal(await context.resolveLocation(), true);
  assert.equal(context.S.label, 'Charlotte, NC');
  assert.equal(requests.length, 1);
  assert.ok(requests[0].startsWith('https://api.bigdatacloud.net/'));
});

test('stale cache fallback does not overwrite newer location', () => {
  const { context } = locationContext({ cached: { lat: 1, lon: 2 } });
  context.S.locSeq = 2;
  assert.equal(context.fallbackLoc(1), false);
  assert.equal(context.S.lat, undefined);
});

test('all coordinate and reverse-geocoding fallbacks use Current location', async () => {
  const { context } = locationContext({ host: enabled });
  assert.equal(context.coordinateLabel(NaN, NaN), 'Current location');
  for (const data of [null, {}]) {
    context.fetch = async () => ({ ok: true, json: async () => data });
    assert.equal(await context.reverseGeocode(1, 2), 'Current location');
  }
  context.fetch = async () => { throw Error('offline'); };
  assert.equal(await context.reverseGeocode(1, 2), 'Current location');
});
