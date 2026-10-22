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

for flag in "$@"; do
    case "$flag" in
        --with-js|--with-appstore)
            printf '%s: not yet configured\n' "$flag"
            ;;
        *)
            printf 'Unknown option: %s\n' "$flag" >&2
            exit 2
            ;;
    esac
done

cd "$(dirname "$0")/.."
mkdir -p build

xcodebuild test -project ÆtherDesk.xcodeproj -scheme AetherDesk \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath "${DERIVED_DATA:-build/gate}" 2>&1 | tee build/gate.log

if ! grep -Fq '** TEST SUCCEEDED **' build/gate.log; then
    printf 'Test gate failed: missing Xcode success marker.\n' >&2
    exit 1
fi
if ! grep -E 'Test run with [0-9]+ tests in [0-9]+ suites passed' build/gate.log; then
    printf 'Test gate failed: missing Swift Testing success summary.\n' >&2
    exit 1
fi
