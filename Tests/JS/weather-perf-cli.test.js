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
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const checker = path.join(root, 'scripts/check-weather-perf.sh');

test('perf checker prints usage for options missing a value', () => {
  for (const option of ['--evaluate', '--wallpaper']) {
    const result = spawnSync('/bin/bash', [checker, option], { encoding: 'utf8' });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /Usage: .*\[--wallpaper weather\|neoncity\] \[--evaluate directory\]/);
  }
});

test('installed-app wait works in a fresh clone and cleans up on exit or timeout', () => {
  const source = fs.readFileSync(checker, 'utf8');
  const wait = source.match(/^wait_for_installed_app\(\) \{\n[\s\S]*?^\}/m)?.[0];
  assert.ok(wait, 'production wait function exists');
  for (const mode of ['exits', 'timeout', 'absent']) {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'weather-perf-wait-'));
    try {
      // Only replace the process check; execute the production wait body and real tee.
      const body = wait.replace('/bin/ps -axo comm=', 'stub_process_check');
      assert.notEqual(body, wait);
      const shell = `set -euo pipefail
stub_process_check() {
  case '${mode}' in
    exits) if [[ ! -f checked ]]; then touch checked; printf '/Applications/ÆtherDesk.app/Contents/MacOS/ÆtherDesk\\n'; fi ;;
    timeout) printf '/Applications/ÆtherDesk.app/Contents/MacOS/ÆtherDesk\\n' ;;
  esac
}
sleep() {
  [[ "$1" == 30 ]]
  [[ -s build/weather-perf-waiting.txt ]]
}
${body}
wait_for_installed_app
`;
      const result = spawnSync('/bin/bash', ['-c', shell], { cwd: directory, encoding: 'utf8', timeout: 5000 });
      assert.ifError(result.error);
      assert.equal(result.status, mode === 'timeout' ? 1 : 0, result.stderr);
      if (mode !== 'absent') assert.match(result.stdout, /Waiting for installed ÆtherDesk/);
      if (mode === 'timeout') assert.match(result.stdout, /elapsed 1800 seconds/);
      assert.equal(fs.existsSync(path.join(directory, 'build/weather-perf-waiting.txt')), false);
      assert.equal(fs.existsSync(path.join(directory, '.superpowers')), false);
    } finally {
      fs.rmSync(directory, { recursive: true, force: true });
    }
  }
});
