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
derived_data="$(mktemp -d "${TMPDIR:-/tmp}/aetherdesk-appstore.XXXXXX")"
trap 'rm -rf "$derived_data"' EXIT

xcodebuild build -project ÆtherDesk.xcodeproj -scheme AetherDesk-AppStore \
    -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath "$derived_data"

app="$derived_data/Build/Products/Release/ÆtherDesk.app"
executable="$app/Contents/MacOS/ÆtherDesk"
if [[ ! -x "$executable" ]]; then
    printf 'App Store check failed: missing app executable.\n' >&2
    exit 1
fi
if [[ -e "$app/Contents/Frameworks/Sparkle.framework" || -L "$app/Contents/Frameworks/Sparkle.framework" ]]; then
    printf 'App Store check failed: Sparkle.framework is embedded.\n' >&2
    exit 1
fi
/usr/bin/plutil -convert xml1 -o "$derived_data/app-info.xml" "$app/Contents/Info.plist"
if grep -Eq '<key>SU[^<]*</key>' "$derived_data/app-info.xml"; then
    printf 'App Store check failed: Info.plist contains Sparkle (SU*) keys.\n' >&2
    exit 1
fi
/usr/bin/otool -L "$executable" > "$derived_data/linked-libraries.txt"
if grep -Fq Sparkle "$derived_data/linked-libraries.txt"; then
    printf 'App Store check failed: executable links Sparkle.\n' >&2
    exit 1
fi
/usr/bin/strings -a "$executable" > "$derived_data/symbol-strings.txt"
if grep -Fq UpdateManager "$derived_data/symbol-strings.txt"; then
    printf 'App Store check failed: executable contains UpdateManager.\n' >&2
    exit 1
fi
if [[ ! -f "$app/Contents/Resources/Acknowledgements.txt" || ! -d "$app/Contents/Resources/Wallpapers" ]]; then
    printf 'App Store check failed: missing Acknowledgements.txt or Wallpapers/.\n' >&2
    exit 1
fi
printf 'App Store build check passed: no Sparkle, SU* keys or UpdateManager; required resources are bundled.\n'
