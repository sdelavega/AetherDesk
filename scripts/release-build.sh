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
[[ $# == 2 || ( $# == 3 && $3 == --unsigned-test ) ]] || fail 'Usage: release-build.sh X.Y.Z BUILD [--unsigned-test]'
version=$1 build=$2 unsigned=false
[[ $# != 3 ]] || unsigned=true
version_check "$version"
[[ $build =~ ^[1-9][0-9]*$ ]] || fail 'Build must be a positive integer'
profile=${NOTARIZE_KEYCHAIN_PROFILE:-AetherDesk}
root=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
cd "$root"
clean_tree "$root"
release_branch "$root"
head=$(tool git rev-parse HEAD)
[[ ! -e dist/$version ]] || fail 'Output already exists; move it aside before rebuilding'
tool mkdir -p dist build
work=$(tool mktemp -d "$root/build/release.XXXXXX")
# The copy contains only committed source, with no credentials or local config.
cleanup() {
    local status=$?
    trap - EXIT
    tool rm -rf "$work"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
tool mkdir -p "$work/source" "$work/output"
tool git archive HEAD | tool tar -x -C "$work/source"
source_root="$work/source"
project='ÆtherDesk.xcodeproj'
# Modify every configuration, then verify both schemes' effective settings.
tool python3 -I - "$source_root/$project/project.pbxproj" "$version" "$build" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
for key, value in zip(("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"), sys.argv[2:]):
    text, count = re.subn(r"\b" + key + r"\s*=\s*[^;]+;", f"{key} = {value};", text)
    if count == 0:
        sys.exit("Missing app version configurations: " + key)
path.write_text(text)
PY
for scheme in AetherDesk AetherDesk-AppStore; do
    tool xcodebuild -showBuildSettings -project "$source_root/$project" -scheme "$scheme" \
        -configuration Release -json > "$work/$scheme.json"
    tool python3 -I - "$work/$scheme.json" "$scheme" "$version" "$build" <<'PY'
import base64, json, sys
rows = json.load(open(sys.argv[1]))
target = {"AetherDesk-AppStore": "AetherDeskAppStore"}.get(sys.argv[2], sys.argv[2])
settings, = [r["buildSettings"] for r in rows if r["target"] == target]
if settings["MARKETING_VERSION"] != sys.argv[3] or settings["CURRENT_PROJECT_VERSION"] != sys.argv[4]:
    sys.exit("Effective version settings mismatch")
if sys.argv[2] == "AetherDesk":
    try:
        public = base64.b64decode(settings["SPARKLE_PUBLIC_ED_KEY"], validate=True)
    except (KeyError, ValueError):
        sys.exit("SPARKLE_PUBLIC_ED_KEY is missing or a placeholder")
    if len(public) != 32 or not any(public):
        sys.exit("SPARKLE_PUBLIC_ED_KEY is missing or a placeholder")
print(sys.argv[2] + ": version/build verified")
PY
done
# The signed path also builds from the copy; only a successful release commits
# its verified version bump back into the original project.
(cd "$source_root" && tool /bin/bash scripts/test-gate.sh --with-js --with-appstore)
derived="$source_root/build/gate"
tool xcodebuild -resolvePackageDependencies -project "$source_root/$project" \
    -scheme AetherDesk -derivedDataPath "$derived"
tool python3 -I - "$source_root/$project/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" <<'PY'
import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
pin, = [p for p in pins if p["identity"] == "sparkle"]
if pin["state"].get("version") != "2.10.0":
    sys.exit("Release requires Sparkle 2.10.0")
PY
tools="$derived/SourcePackages/artifacts/sparkle/Sparkle/bin"
verify_sparkle_tools "$root" "$tools"
archive="$work/AetherDesk.xcarchive"
export_dir="$work/export"
archive_args=(-project "$source_root/$project" -scheme AetherDesk -configuration Release
    -destination 'generic/platform=macOS' -derivedDataPath "$derived" -archivePath "$archive"
    'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO)
if "$unsigned"; then
    printf '%s\n' 'Developer ID signing: skipped (unsigned-test)'
    tool xcodebuild archive "${archive_args[@]}" CODE_SIGNING_ALLOWED=NO
    # Xcode's Developer ID exporter requires a signing identity. An unsigned
    # export copies the archived product and ad-hoc signs it without a keychain.
    tool mkdir -p "$export_dir"
    tool ditto "$archive/Products/Applications/ÆtherDesk.app" "$export_dir/ÆtherDesk.app"
    tool codesign --force --deep --sign - "$export_dir/ÆtherDesk.app"
else
    tool xcodebuild archive "${archive_args[@]}" CODE_SIGN_STYLE=Manual \
        'CODE_SIGN_IDENTITY=Developer ID Application' DEVELOPMENT_TEAM=N5PUFD82GV
    if [[ -f $root/ExportOptions.plist ]]; then
        tool cp "$root/ExportOptions.plist" "$work/ExportOptions.plist"
    else
        tool python3 -I - "$work/ExportOptions.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], "wb") as output:
    plistlib.dump(dict(method="developer-id", signingStyle="manual", teamID="N5PUFD82GV",
                      signingCertificate="Developer ID Application"), output)
PY
    fi
    tool xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
        -exportOptionsPlist "$work/ExportOptions.plist"
fi
app="$export_dir/ÆtherDesk.app"
tool codesign --verify --deep --strict "$app"
if "$unsigned"; then
    printf '%s\n' 'App notarization and stapling: skipped (unsigned-test)'
else
    tool ditto -c -k --keepParent "$app" "$work/notarize.zip"
    tool xcrun notarytool submit "$work/notarize.zip" --keychain-profile "$profile" --wait --output-format json > "$work/notary-app.json"
    tool python3 -I - "$work/notary-app.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1])).get("status") != "Accepted":
    sys.exit("App notarization was not Accepted")
PY
    tool xcrun stapler staple "$app"
    tool xcrun stapler validate "$app"
    tool spctl --assess --type execute "$app"
fi
output="$work/output"
tool ditto -c -k --keepParent "$app" "$output/AetherDesk.zip"
(cd "$output" && tool shasum -a 256 AetherDesk.zip > AetherDesk.zip.sha256)
if "$unsigned"; then
    tool /bin/bash "$root/scripts/make-dmg.sh" "$version" "$app" "$output/AetherDesk-$version.dmg" --unsigned-test
    printf '%s\n' 'DMG notarization and stapling: skipped (unsigned-test)'
else
    tool /bin/bash "$root/scripts/make-dmg.sh" "$version" "$app" "$output/AetherDesk-$version.dmg" 'Developer ID Application'
    tool xcrun notarytool submit "$output/AetherDesk-$version.dmg" --keychain-profile "$profile" --wait --output-format json > "$work/notary-dmg.json"
    tool python3 -I - "$work/notary-dmg.json" <<'PY'
import json, sys
if json.load(open(sys.argv[1])).get("status") != "Accepted":
    sys.exit("DMG notarization was not Accepted")
PY
    tool xcrun stapler staple "$output/AetherDesk-$version.dmg"
    tool xcrun stapler validate "$output/AetherDesk-$version.dmg"
fi
handover_status=0
tool /bin/bash "$root/scripts/check-v13-handover.sh" "$output/AetherDesk.zip" > "$work/handover.log" 2>&1 || handover_status=$?
tool cat "$work/handover.log"
if "$unsigned"; then
    [[ $handover_status == 1 ]] || fail 'Unsigned handover must fail at the team check'
    tool grep -Eq 'TeamIdentifier mismatch: update team (unknown|not set), expected N5PUFD82GV$' "$work/handover.log" || fail 'Handover failed before the expected ad-hoc team rejection'
    printf '%s\n' 'Expected unsigned-test handover rejection: PASS (size, hash and extraction reached team check)'
    printf '%s\n' 'Sparkle appcast signing: skipped (unsigned-test)'
else
    [[ $handover_status == 0 ]] || fail 'v1.3 handover failed'
    tool mkdir -p "$work/feed"
    tool cp "$output/AetherDesk.zip" "$work/feed/AetherDesk.zip"
    # Sparkle alone reads account AetherDesk from the keychain. No private key
    # is exported, copied into the environment or passed to another process.
    tool "$tools/generate_appcast" --account AetherDesk --maximum-deltas 0 \
        --download-url-prefix "https://github.com/sdelavega/AetherDesk/releases/download/v$version/" "$work/feed"
    tool cp "$work/feed/appcast.xml" "$output/appcast.xml"
    tool python3 -I - "$output" "$app/Contents/Info.plist" "$version" "$build" > "$work/verify-input" <<'PY'
import base64, pathlib, plistlib, sys, xml.etree.ElementTree as ET
root, info, version, build = sys.argv[1:]
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
item, = ET.parse(pathlib.Path(root) / "appcast.xml").findall("./channel/item")
e = item.find("enclosure")
assert e is not None
assert (item.findtext(ns + "version") or e.get(ns + "version")) == build
assert (item.findtext(ns + "shortVersionString") or e.get(ns + "shortVersionString")) == version
assert e.get("url") == f"https://github.com/sdelavega/AetherDesk/releases/download/v{version}/AetherDesk.zip"
assert e.get("length") == str((pathlib.Path(root) / "AetherDesk.zip").stat().st_size)
assert item.findtext(ns + "minimumSystemVersion") == "14.0"
public = base64.b64decode(plistlib.load(open(info, "rb"))["SUPublicEDKey"], validate=True)
assert len(public) == 32
# Sparkle 2.10.0's legacy 96-byte verification input uses only the public
# suffix. The zero prefix is inert padding and never a private signing key.
print(base64.b64encode(bytes(64) + public).decode())
print(e.attrib[ns + "edSignature"])
PY
    { IFS= read -r public_verify_input; IFS= read -r signature; } < "$work/verify-input"
    printf '%s\n' "$public_verify_input" | tool "$tools/sign_update" --verify "$output/AetherDesk.zip" "$signature" --ed-key-file -
    clean_tree "$root"
    [[ $(tool git rev-parse HEAD) == "$head" ]] || fail 'HEAD changed during release'
    tool cp "$source_root/$project/project.pbxproj" "$root/$project/project.pbxproj"
    if ! tool git diff --quiet -- "$project/project.pbxproj"; then
        tool git add -- "$project/project.pbxproj"
        tool git commit -m "Bump release version to $version ($build)" -m 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>'
    fi
    head=$(tool git rev-parse HEAD)
fi
mode=signed
if "$unsigned"; then mode='unsigned-test'; fi
printf 'mode=%s\nversion=%s\nbuild=%s\ncommit=%s\n' "$mode" "$version" "$build" "$head" > "$output/release-info.txt"
# Publish the complete directory atomically; failed runs leave no candidate.
# The final directory name is used in manifest verification, not generation.
manifest write "$output"
tool mv "$output" "$root/dist/$version"
clean_tree "$root"
printf 'Built dist/%s (%s)\n' "$version" "$mode"
