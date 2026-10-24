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
import { execFileSync } from 'node:child_process';
import vm from 'node:vm';

const root = new URL('../../', import.meta.url);
const functions = ['fetchWithTimeout', 'cacheLocation', 'loadCachedLocation', 'resolveLocation',
  'autoLocation', 'hasHostCapability', 'coordinateLabel', 'reverseGeocode', 'fetchIP',
  'fallbackLoc', 'geocodeManual', 'buildForecastUrl'];
const source = vm.createContext({});
vm.runInContext(readFileSync(new URL('Resources/Wallpapers/WeatherAether/js/weather.js', root), 'utf8'), source);
function bodies(text) {
  const context = vm.createContext({});
  context.window = context;
  vm.runInContext(text, context);
  return context.createSharedWeather({}, () => {}, () => {}, () => {});
}
function assertNoDrift(text) {
  const copied = bodies(text);
  assert.deepEqual(Object.keys(copied).sort(), [...functions].sort());
  for (const name of functions) assert.equal(copied[name].toString(), source[name].toString(), `${name} drifted`);
}
function copy() {
  return readFileSync(new URL('Resources/Wallpapers/NeonCity/js/weather-shared/weather.js', root), 'utf8');
}
test('shared weather functions match WeatherAether verbatim, ignoring license headers', () => {
  const text = copy();
  assert.match(text, /^\/\/ SPDX-License-Identifier: MIT\n\/\/ Copyright \(c\) 2026 Stephen de la Vega/);
  assertNoDrift(text);
});
test('drift comparison rejects an edited copy', () => {
  const text = copy();
  assert.ok(text.includes('return autoLocation(seq);'));
  assert.throws(() => assertNoDrift(text.replace('return autoLocation(seq);', 'return Promise.resolve(false);')), /resolveLocation drifted/);
});
test('sync script reproduces the checked-in module', () => {
  const generated = execFileSync('bash', ['scripts/sync-shared-weather.sh', '--stdout'], { cwd: root, encoding: 'utf8' });
  assert.equal(generated, copy());
});
