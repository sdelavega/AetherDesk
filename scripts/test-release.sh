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
# shellcheck source=scripts/release-lib.sh
source "${BASH_SOURCE[0]%/*}/release-lib.sh"
root=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/aetherdesk-release-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
expect_failure() {
    local expected=$1
    shift
    if ( "$@" ) > "$work/failure.log" 2>&1; then fail 'Expected failure was accepted'; fi
    grep -Fq "$expected" "$work/failure.log" || { cat "$work/failure.log"; fail 'Wrong failure'; }
}
# Stub security in a subshell so no real keychain is queried and PATH is restored.
(
    mkdir -p "$work/bin"
    cat > "$work/bin/security" <<'SH'
#!/bin/bash
[[ $# == 5 && $1 == find-identity && $2 == -v && $3 == -p && $4 == codesigning && $5 == "$HOME/Library/Keychains/login.keychain-db" ]] || exit 2
cat "${0%/*}/identities"
SH
    chmod +x "$work/bin/security"
    export PATH="$work/bin:$PATH"
    cat > "$work/bin/identities" <<'IDENTITIES'
  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Apple Development: Stephen de la Vega (N5PUFD82GV)"
  2) BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB "Developer ID Application: Other Team (XXXXXXXXXX)"
  3) 0123456789ABCDEF0123456789ABCDEF01234567 "Developer ID Application: Stephen de la Vega (N5PUFD82GV)"
  4) BADHASH "Developer ID Application: Stephen de la Vega (N5PUFD82GV)"
     4 valid identities found
IDENTITIES
    identity=$(developer_id_identity)
    [[ $identity == 0123456789ABCDEF0123456789ABCDEF01234567 && $identity =~ ^[A-Fa-f0-9]{40}$ ]]
    printf '%s\n' '  5) CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC "Developer ID Application: Second Certificate (N5PUFD82GV)"' >> "$work/bin/identities"
    expect_failure 'Multiple Developer ID Application identities' developer_id_identity
    sed '/0123456789ABCDEF0123456789ABCDEF01234567/d; /CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC/d' "$work/bin/identities" > "$work/no-match"
    cp "$work/no-match" "$work/bin/identities"
    expect_failure 'No Developer ID Application identity' developer_id_identity
    printf '     0 valid identities found\n' > "$work/bin/identities"
    expect_failure 'No Developer ID Application identity' developer_id_identity
)
printf '%s\n' 'PASS: login-keychain identity hash selection and missing/ambiguous identity rejection'
# Test presence, never print any environment names or values.
RELEASE_TEST_SENTINEL=must-not-leak
export RELEASE_TEST_SENTINEL
# Perl observes the supplied environment without Python's macOS launcher
# adding runtime bookkeeping. The test emits no environment data.
tool /usr/bin/perl -e '
    for (keys %ENV) {
        exit 1 unless /\A(?:PATH|HOME|TMPDIR|LANG|LC_.*|USER|DEVELOPER_DIR)\z/;
    }
'
printf '%s\n' 'PASS: child environment allowlist'
expect_failure 'Version must be X.Y.Z' /bin/bash "$root/scripts/release-build.sh" bad 41 --unsigned-test
expect_failure 'Build must be a positive integer' /bin/bash "$root/scripts/release-build.sh" 1.4.0 0 --unsigned-test
expect_failure 'Usage:' /bin/bash "$root/scripts/release-publish.sh" 1.4.0 --unknown
# The dry-run is safe with missing artifacts and with either clean or dirty trees.
before=$(git -C "$root" status --porcelain=v1 --untracked-files=all)
/bin/bash "$root/scripts/release-publish.sh" 1.4.0 > "$work/plan.txt"
[[ $before == "$(git -C "$root" status --porcelain=v1 --untracked-files=all)" ]]
grep -Fq 'gh release create v1.4.0' "$work/plan.txt"
grep -Fq 'Verify origin main matches the built HEAD; fail if main moved.' "$work/plan.txt"
grep -Fq 'Copy dist/1.4.0/appcast.xml to docs/appcast.xml in the main checkout.' "$work/plan.txt"
grep -Fq 'Commit only docs/appcast.xml (Publish appcast for 1.4.0); push main fast-forward only.' "$work/plan.txt"
if grep -Eq 'gh-pages|detached temporary worktree' "$work/plan.txt"; then fail 'Obsolete Pages publishing plan'; fi
if git -C "$root" check-ignore -q docs/appcast.xml; then fail 'Published appcast must not be ignored'; fi
printf '%s\n' 'PASS: argument rejection and side-effect-free publish plan'
# Exercise manifest integrity, incomplete-manifest rejection and unsigned block.
mkdir -p "$work/1.4.0"
fixture="$work/1.4.0"
for name in AetherDesk.zip AetherDesk.zip.sha256 AetherDesk-1.4.0.dmg appcast.xml; do
    printf 'fixture\n' > "$fixture/$name"
done
printf 'mode=signed\n' > "$fixture/release-info.txt"
manifest write "$fixture"
manifest verify "$fixture"
printf 'corruption\n' >> "$fixture/AetherDesk.zip"
expect_failure 'Manifest mismatch' manifest verify "$fixture"
manifest write "$fixture"
printf 'mode=unsigned-test\n' > "$fixture/release-info.txt"
manifest write "$fixture"
expect_failure 'Unsigned-test artifacts cannot be published' manifest verify "$fixture"
printf 'mode=signed\n' > "$fixture/release-info.txt"
manifest write "$fixture"
sed '$d' "$fixture/manifest.txt" > "$work/incomplete"
cp "$work/incomplete" "$fixture/manifest.txt"
expect_failure 'Manifest must cover every release artifact exactly once' manifest verify "$fixture"
printf '%s\n' 'PASS: manifest validation rejects corruption, omissions and unsigned artifacts'
# Real pinned tools are verified independently of any signing/keychain operation.
verify_sparkle_tools "$root" "$root/build/gate/SourcePackages/artifacts/sparkle/Sparkle/bin"
printf '%s\n' 'Release pipeline checks passed'
