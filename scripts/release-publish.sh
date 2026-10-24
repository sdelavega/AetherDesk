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
[[ $# == 1 || ( $# == 2 && $2 == --execute ) ]] || fail 'Usage: release-publish.sh X.Y.Z [--execute]'
version=$1
version_check "$version"
root=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
tag="v$version"
feed_url=https://sdelavega.github.io/AetherDesk/appcast.xml
asset_url="https://github.com/sdelavega/AetherDesk/releases/download/$tag"
# Return before preflight, network, temporary files, git fetch or worktree edits.
printf '%s\n' \
    "Plan for $tag (no actions without --execute):" \
    "  Verify dist/$version/manifest.txt, signed marker, commit, handover and stapled DMG." \
    "  Require typed confirmation: $version" \
    "  gh release create $tag with AetherDesk.zip, AetherDesk.zip.sha256, AetherDesk-$version.dmg (repo sdelavega/AetherDesk; target verified HEAD)." \
    '  Fetch origin gh-pages; create a detached temporary worktree.' \
    "  Copy dist/$version/appcast.xml; commit appcast.xml and push HEAD:gh-pages; remove worktree." \
    "  Render packaging/aetherdesk.rb.template with version $version and DMG SHA-256." \
    "  Write ../homebrew-tap/Casks/aetherdesk.rb; commit only that path and push the tap branch." \
    "  Fetch $feed_url and all three release assets; compare SHA-256 and size with manifest.txt."
[[ $# == 2 ]] || exit 0
cd "$root"
clean_tree "$root"
release_branch "$root"
dist="$root/dist/$version"
manifest verify "$dist"
head=$(tool git rev-parse HEAD)
tool grep -Fxq "commit=$head" "$dist/release-info.txt" || fail 'Release must be built from current HEAD'
tool grep -Fxq "version=$version" "$dist/release-info.txt" || fail 'Release version mismatch'
(cd "$dist" && tool shasum -a 256 -c AetherDesk.zip.sha256)
tool /bin/bash scripts/check-v13-handover.sh "$dist/AetherDesk.zip"
tool xcrun stapler validate "$dist/AetherDesk-$version.dmg"
tool spctl --assess --type open --context context:primary-signature "$dist/AetherDesk-$version.dmg"
tap=$(cd "$root/../homebrew-tap" && pwd)
[[ $(tool git -C "$tap" rev-parse --show-toplevel) == "$tap" ]] || fail 'Tap must be a repository root'
clean_tree "$tap"
case "$(tool git -C "$tap" remote get-url origin)" in
    https://github.com/sdelavega/homebrew-tap|https://github.com/sdelavega/homebrew-tap.git|git@github.com:sdelavega/homebrew-tap.git) ;;
    *) fail 'Unexpected homebrew-tap origin' ;;
esac
[[ -n $(tool git -C "$tap" branch --show-current) ]] || fail 'Tap must have a branch checked out'
answer=
printf 'Type %s to publish: ' "$version"
IFS= read -r answer || fail 'Confirmation required'
[[ $answer == "$version" ]] || fail 'Confirmation must match the version exactly'
work=$(tool mktemp -d "${TMPDIR:-/tmp}/aetherdesk-publish.XXXXXX")
pages="$work/pages"
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -d $pages ]]; then tool git worktree remove --force "$pages" || true; fi
    tool rm -rf "$work"
    if [[ $status != 0 ]]; then
        printf '%s\n' 'Publish stopped. Inspect remote release, gh-pages and tap before retrying; no rollback was attempted.' >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Pre-render and validate before any remote mutation.
sha=$(tool shasum -a 256 "$dist/AetherDesk-$version.dmg")
sha=${sha%% *}
tool python3 -I - "$root/packaging/aetherdesk.rb.template" "$version" "$sha" "$work/aetherdesk.rb" <<'PY'
import pathlib, re, sys
source, version, sha, output = sys.argv[1:]
text = pathlib.Path(source).read_text().replace("@VERSION@", version).replace("@SHA256@", sha)
if not re.fullmatch(r"[0-9a-f]{64}", sha) or re.search(r"@[A-Z0-9_]+@", text):
    sys.exit("Invalid cask render")
pathlib.Path(output).write_text(text)
PY
# Validate access and an existing feed branch before creating the release.
tool git fetch origin gh-pages
tool git worktree add --detach "$pages" FETCH_HEAD
# gh authenticates using its local keychain/config; no credential environment
# variables are forwarded to child tools.
tool gh release create "$tag" "$dist/AetherDesk.zip" "$dist/AetherDesk.zip.sha256" \
    "$dist/AetherDesk-$version.dmg" --repo sdelavega/AetherDesk --target "$head" \
    --title "ÆtherDesk $version" --notes "ÆtherDesk $version for macOS 14 or later."
tool cp "$dist/appcast.xml" "$pages/appcast.xml"
tool git -C "$pages" add -- appcast.xml
tool git -C "$pages" commit -m "Release $tag appcast" -m 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
tool git -C "$pages" push origin HEAD:refs/heads/gh-pages
tool git worktree remove "$pages"
clean_tree "$tap"
tool cp "$work/aetherdesk.rb" "$tap/Casks/aetherdesk.rb"
tool git -C "$tap" add -- Casks/aetherdesk.rb
tool git -C "$tap" commit -m "AetherDesk $version" -m 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
tool git -C "$tap" push origin HEAD
# Retry boundedly for Pages/CDN propagation. Every response must match the
# manifest; a successful HTTP response alone is insufficient.
for name in appcast.xml AetherDesk.zip AetherDesk.zip.sha256 "AetherDesk-$version.dmg"; do
    url="$asset_url/$name"
    if [[ $name == appcast.xml ]]; then url=$feed_url; fi
    matched=false
    for ((attempt=1; attempt<=24; attempt++)); do
        if tool curl --fail --location --silent --show-error --max-time 20 --output "$work/download" "$url" &&
            tool python3 -I - "$dist/manifest.txt" "$name" "$work/download" <<'PY'
import hashlib, pathlib, sys
rows = [line.split("  ") for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
sha, size, _ = next(row for row in rows if row[2] == sys.argv[2])
path = pathlib.Path(sys.argv[3])
sys.exit(0 if str(path.stat().st_size) == size and hashlib.sha256(path.read_bytes()).hexdigest() == sha else 1)
PY
        then
            matched=true
            break
        fi
        if [[ $attempt != 24 ]]; then tool sleep 5; fi
    done
    "$matched" || fail "Published checksum mismatch: $name"
done
printf '%s\n' 'Published appcast and release asset checks passed'
