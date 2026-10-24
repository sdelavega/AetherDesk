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

with_js=false
with_appstore=false
for flag in "$@"; do
    case "$flag" in
        --with-js)
            with_js=true
            ;;
        --with-appstore)
            with_appstore=true
            ;;
        *)
            printf 'Unknown option: %s\n' "$flag" >&2
            exit 2
            ;;
    esac
done

cd "$(dirname "$0")/.."
mkdir -p build

if "$with_js"; then
    if ! command -v node >/dev/null 2>&1; then
        printf 'Test gate failed: --with-js requires Node.js (node was not found).\n' >&2
        exit 1
    fi
    node --test Tests/JS/ 2>&1 | tee build/gate-js.log
fi

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

if "$with_appstore"; then
    xcodebuild build -project ÆtherDesk.xcodeproj -scheme AetherDesk \
        -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
        -derivedDataPath "${DERIVED_DATA:-build/gate}" 2>&1 | tee build/gate-oss-release.log

    oss_app="${DERIVED_DATA:-build/gate}/Build/Products/Release/ÆtherDesk.app"
    if [[ ! -d "$oss_app/Contents/Frameworks/Sparkle.framework" ]]; then
        printf 'Test gate failed: OSS app is missing Sparkle.framework.\n' >&2
        exit 1
    fi
    /usr/bin/otool -L "$oss_app/Contents/MacOS/ÆtherDesk" > build/gate-oss-linked-libraries.txt
    if ! grep -Fq '@rpath/Sparkle.framework/' build/gate-oss-linked-libraries.txt; then
        printf 'Test gate failed: OSS executable does not link Sparkle.\n' >&2
        exit 1
    fi
    oss_info="$oss_app/Contents/Info.plist"
    if [[ "$(/usr/bin/plutil -extract SUFeedURL raw -o - "$oss_info")" != 'https://sdelavega.github.io/AetherDesk/appcast.xml' ||
          "$(/usr/bin/plutil -extract SUPublicEDKey raw -o - "$oss_info")" != 'GMrlcvxY6lb2wQudMnVWsi8Ox2/mJ8RpMEZcxAKz9sU=' ]]; then
        printf 'Test gate failed: OSS Info.plist has missing or incorrect Sparkle feed/public key.\n' >&2
        exit 1
    fi
    printf 'OSS build check passed: Sparkle.framework is embedded and linked; feed and public key are correct.\n'

    oss_resources="${DERIVED_DATA:-build/gate}/Build/Products/Release/ÆtherDesk.app/Contents/Resources"
    if [[ ! -f "$oss_resources/Acknowledgements.txt" || ! -d "$oss_resources/Wallpapers" ]]; then
        printf 'Test gate failed: OSS app is missing Acknowledgements.txt or Wallpapers/.\n' >&2
        exit 1
    fi

    scripts/check-appstore-build.sh 2>&1 | tee build/gate-appstore.log
fi
