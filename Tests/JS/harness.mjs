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

import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const wallpaperRoot = new URL('../../Resources/Wallpapers/WeatherAether/', import.meta.url);

export function loadWeatherAether(files, stubs = {}) {
  const storage = new Map();
  const context = vm.createContext({
    document: { getElementById: () => null, querySelector: () => null },
    navigator: {},
    localStorage: {
      getItem: key => storage.get(String(key)) ?? null,
      setItem: (key, value) => storage.set(String(key), String(value)),
      removeItem: key => storage.delete(String(key)),
      clear: () => storage.clear()
    },
    ...stubs
  });
  context.window = context;
  Object.assign(context, stubs.window);
  for (const file of files) {
    vm.runInContext(readFileSync(new URL(file, wallpaperRoot), 'utf8'), context, { filename: file });
  }
  return context;
}
