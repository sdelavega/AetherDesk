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

if [[ ${BASH_ENV+x} || -n $(builtin compgen -A function) ]]; then
    builtin printf '%s\n' 'Release requires no inherited shell state' >&2
    exit 1
fi
set -euo pipefail
# shellcheck source=scripts/release-lib.sh
source "${BASH_SOURCE[0]%/*}/release-lib.sh"
[[ $# == 4 ]] || fail 'Usage: make-dmg.sh X.Y.Z APP OUTPUT IDENTITY|--unsigned-test'
version_check "$1"
[[ -d $2 && ! -e $3 ]] || fail 'App must exist and output must not exist'
stage=$(tool mktemp -d "${TMPDIR:-/tmp}/aetherdesk-dmg.XXXXXX")
trap 'tool rm -rf "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
tool ditto "$2" "$stage/ÆtherDesk.app"
tool ln -s /Applications "$stage/Applications"
# srcfolder creates the image without mounting it or writing under /Volumes.
tool hdiutil create -srcfolder "$stage" -volname "ÆtherDesk $1" -format UDZO "$3"
if [[ $4 == --unsigned-test ]]; then
    printf '%s\n' 'DMG Developer ID signing: skipped (unsigned-test)'
else
    [[ $4 == 'Developer ID Application'* || $4 =~ ^[A-Fa-f0-9]{40}$ ]] || fail 'A Developer ID Application identity is required'
    tool codesign --timestamp --sign "$4" "$3"
    tool codesign --verify --strict "$3"
fi
