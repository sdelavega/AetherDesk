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

# Child tools receive only this allowlist. Values travel over a private pipe,
# never an environment dump, command-line argument or log file.
tool() (
    local name
    local -a allowed=()
    while IFS= read -r name; do
        case "$name" in
            PATH|HOME|TMPDIR|LANG|LC_*|USER|DEVELOPER_DIR) allowed+=("$name=${!name}") ;;
        esac
    done < <(builtin compgen -e)
    # The inner shell imports the private pipe; expansion must happen there.
    # shellcheck disable=SC2016
    /usr/bin/env -i /bin/bash --noprofile --norc -c '
        while IFS= read -r -d "" entry <&9; do
            case "${entry%%=*}" in
                PATH|HOME|TMPDIR|LANG|LC_*|USER|DEVELOPER_DIR) builtin export "$entry" ;;
            esac
        done
        exec 9<&-
        # Bash adds these automatically; strip them before the actual tool.
        exec /usr/bin/env -u PWD -u SHLVL -u _ "$@"
    ' bash "$@" 9< <(builtin printf '%s\0' "${allowed[@]}")
)

fail() { printf '%s\n' "$*" >&2; exit 1; }
version_check() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'Version must be X.Y.Z'; }
clean_tree() { [[ -z $(tool git -C "$1" status --porcelain --untracked-files=all) ]] || fail 'Release requires a clean tree'; }
release_branch() {
    case "$(tool git -C "$1" branch --show-current)" in
        v1.4|main) ;;
        *) fail 'Release requires v1.4 or main' ;;
    esac
}

verify_sparkle_tools() {
    local root=$1 tools=$2
    [[ -x $tools/generate_appcast && -x $tools/sign_update ]] || fail 'Resolve Sparkle 2.10.0 before using its tools'
    (cd "$tools" && tool shasum -a 256 -c "$root/scripts/sparkle-tools.sha256")
}

# The manifest covers precisely these artifacts; unsigned rehearsals deliberately
# have no appcast and carry a marker which the publishing preflight rejects.
manifest() {
    tool python3 -I - "$@" <<'PY'
import hashlib, pathlib, sys
mode, directory = sys.argv[1:]
root = pathlib.Path(directory)
names = ["AetherDesk.zip", "AetherDesk.zip.sha256", "release-info.txt"]
names += [p.name for p in root.glob("AetherDesk-*.dmg")]
if (root / "appcast.xml").exists():
    names.append("appcast.xml")
expected = {"AetherDesk.zip", "AetherDesk.zip.sha256", "release-info.txt",
            f"AetherDesk-{root.name}.dmg", "appcast.xml"}
if mode == "verify":
    if not (root / "release-info.txt").read_text().startswith("mode=signed\n"):
        sys.exit("Unsigned-test artifacts cannot be published")
    rows = [line.split("  ") for line in (root / "manifest.txt").read_text().splitlines()]
    if len(rows) != len(expected) or {r[2] for r in rows if len(r) == 3} != expected:
        sys.exit("Manifest must cover every release artifact exactly once")
    for sha, size, name in rows:
        path = root / name
        if path.is_symlink() or str(path.stat().st_size) != size or hashlib.sha256(path.read_bytes()).hexdigest() != sha:
            sys.exit("Manifest mismatch: " + name)
else:
    rows = []
    for name in sorted(names):
        path = root / name
        rows.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.stat().st_size}  {name}\n")
    (root / "manifest.txt").write_text("".join(rows))
PY
}
