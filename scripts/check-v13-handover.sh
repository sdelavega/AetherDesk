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

if [[ $# -ne 1 || ! -f "$1" ]]; then
    printf 'Usage: %s <AetherDesk.zip> (requires <zip>.sha256)\n' "$0" >&2
    exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir -p "$root/build"
handover_dir="$(mktemp -d "$root/build/v13-handover.XXXXXX")"
trap 'rm -rf "$handover_dir"' EXIT

# R30: transform only this temporary tagged copy, never working-tree sources.
git -C "$root" show v1.3:Core/UpdateManager.swift \
    | /usr/bin/perl -pe 's/\bprivate\b/internal/g' > "$handover_dir/UpdateManager.swift"
git -C "$root" show v1.3:App/Constants.swift > "$handover_dir/Constants.swift"
/usr/bin/patch --batch --forward --fuzz=0 "$handover_dir/UpdateManager.swift" \
    < "$root/Tools/V13Handover/expose.patch"

# V13_HANDOVER excludes all network, install, termination and relaunch methods.
xcrun swiftc -swift-version 5 -D V13_HANDOVER -parse-as-library \
    "$handover_dir/UpdateManager.swift" "$handover_dir/Constants.swift" \
    "$root/Tools/V13Handover/shim.swift" -o "$handover_dir/check-v13-handover"
"$handover_dir/check-v13-handover" "$archive" "$handover_dir/extracted"
