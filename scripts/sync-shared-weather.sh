#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Stephen de la Vega
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

set -euo pipefail
cd "$(dirname "$0")/.."
node --input-type=module - "$@" <<'NODE'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import vm from 'node:vm';
const args = process.argv.slice(2);
if (args.length > 1 || (args.length && args[0] !== '--stdout')) {
  throw new Error('Usage: sync-shared-weather.sh [--stdout]');
}
const names = ['fetchWithTimeout', 'cacheLocation', 'loadCachedLocation', 'resolveLocation',
  'autoLocation', 'hasHostCapability', 'coordinateLabel', 'reverseGeocode', 'fetchIP',
  'fallbackLoc', 'geocodeManual', 'buildForecastUrl'];
const context = vm.createContext({});
vm.runInContext(readFileSync('Resources/Wallpapers/WeatherAether/js/weather.js', 'utf8'), context);
const text = '// SPDX-License-Identifier: MIT\n// Copyright (c) 2026 Stephen de la Vega\n' +
  '// See ../../LICENSE.txt for the MIT license.\n' +
  "'use strict';\n\nwindow.createSharedWeather = function(S, showPill, hidePill, refreshWeather) {\n" +
  names.map(name => context[name].toString()).join('\n\n') +
  '\n\nreturn { ' + names.join(', ') + ' };\n};\n';
if (args[0] === '--stdout') process.stdout.write(text);
else {
  const dir = 'Resources/Wallpapers/NeonCity/js/weather-shared';
  mkdirSync(dir, { recursive: true });
  writeFileSync(`${dir}/weather.js`, text);
}
NODE
