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

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { loadWeatherAether } from './harness.mjs';

const matrix = JSON.parse(readFileSync(new URL('./condition-matrix.json', import.meta.url), 'utf8'));
const states = ['clear', 'partly', 'overcast', 'fog', 'rain', 'freezing', 'snow', 'thunder', 'hail'];
const context = loadWeatherAether(['js/main.js', 'js/atmosphere.js']);

test('matrix covers every WMO description and the extra fallback code', () => {
  assert.deepEqual(Object.keys(matrix.wmo).map(Number).sort((a, b) => a - b),
    [...new Set([...Object.keys(context.WMO_DESC).map(Number), 4, 5, 7, 68])].sort((a, b) => a - b));
  assert.deepEqual([...new Set(Object.values(matrix.wmo))].sort(), [...states].sort());
});

for (const [rawCode, expected] of Object.entries(matrix.wmo)) {
  const code = Number(rawCode);
  test(`WMO ${code} selects ${expected}`, () => {
    assert.equal(context.wmoBucket(code), expected);
    assert.ok(states.includes(context.wmoBucket(code)));
    const atmosphere = context.deriveAtmosphericState({ current: { weather_code: code } });
    assert.equal(atmosphere.condition, expected);
  });
}

test('rain intensity increases within one shared state', () => {
  const atmospheres = [61, 63, 65].map(code => context.deriveAtmosphericState({
    current: { weather_code: code, is_day: 1, wind_speed_10m: 0 }, _units: 'metric'
  }));
  assert.deepEqual(atmospheres.map(value => value.condition), ['rain', 'rain', 'rain']);
  const intensities = atmospheres.map(value => value.precipitationIntensity);
  assert.ok(intensities[0] > 0 && intensities[0] < intensities[1]);
  assert.ok(intensities[1] < intensities[2] && intensities[2] <= 1);
  for (const atmosphere of atmospheres) {
    assert.equal(atmosphere.precipitation, atmosphere.precipitationIntensity);
  }
});

test('harness contexts isolate script globals and local storage and accept stubs', () => {
  const first = loadWeatherAether(['js/main.js'], { navigator: { language: 'en' }, window: { innerWidth: 800 } });
  const second = loadWeatherAether(['js/main.js']);
  first.S.props.units = 'metric';
  first.localStorage.setItem('weather', 'cached');
  assert.equal(second.S.props.units, 'imperial');
  assert.equal(second.localStorage.getItem('weather'), null);
  assert.equal(first.navigator.language, 'en');
  assert.equal(first.cssW(), 800);
  assert.equal(first.window, first);
});
