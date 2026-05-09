// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega. All rights reserved.
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

import Testing

@Suite("SemanticVersion") struct SemanticVersionTests {

    @Test func newerMajor() {
        #expect(SemanticVersion.compare("2.0.0", isGreaterThan: "1.0.0"))
    }

    @Test func newerMinor() {
        #expect(SemanticVersion.compare("1.1.0", isGreaterThan: "1.0.0"))
    }

    @Test func newerPatch() {
        #expect(SemanticVersion.compare("1.0.1", isGreaterThan: "1.0.0"))
    }

    @Test func doubleDigitPatch() {
        // "1.0.10" must beat "1.0.9" numerically, not lexicographically
        #expect(SemanticVersion.compare("1.0.10", isGreaterThan: "1.0.9"))
    }

    @Test func equalVersions() {
        #expect(!SemanticVersion.compare("1.0.6", isGreaterThan: "1.0.6"))
    }

    @Test func olderVersion() {
        #expect(!SemanticVersion.compare("1.0.5", isGreaterThan: "1.0.6"))
    }

    @Test func missingPatchTreatedAsZero() {
        #expect(SemanticVersion.compare("1.1", isGreaterThan: "1.0.0"))
        #expect(!SemanticVersion.compare("1.0", isGreaterThan: "1.0.0"))
    }

    @Test func fourComponentVersion() {
        #expect(SemanticVersion.compare("1.0.0.1", isGreaterThan: "1.0.0"))
    }
}
