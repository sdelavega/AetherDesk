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

import Foundation

/// Numeric semantic version comparison. Handles "1.0.10" > "1.0.9" correctly.
/// Missing components are treated as 0, so "1.1" == "1.1.0".
enum SemanticVersion {

    /// Returns true if `lhs` represents a strictly newer version than `rhs`.
    /// Handles pre-release suffixes per semver: a pre-release version is
    /// always lower than the corresponding release (1.0.0-beta < 1.0.0).
    static func compare(_ lhs: String, isGreaterThan rhs: String) -> Bool {
        // Strip build metadata (everything after '+').
        let lhsClean = lhs.split(separator: "+").first.map(String.init) ?? lhs
        let rhsClean = rhs.split(separator: "+").first.map(String.init) ?? rhs

        // Split into numeric core and pre-release suffix.
        func splitCore(_ v: String) -> (core: String, preRelease: String?) {
            if let dash = v.firstIndex(of: "-") {
                return (String(v[..<dash]), String(v[v.index(after: dash)...]))
            }
            return (v, nil)
        }

        let (lhsCore, lhsPre) = splitCore(lhsClean)
        let (rhsCore, rhsPre) = splitCore(rhsClean)

        // Compare numeric core components.
        let lhsParts = lhsCore.split(separator: ".").map(String.init)
        let rhsParts = rhsCore.split(separator: ".").map(String.init)
        let count = max(lhsParts.count, rhsParts.count)

        for i in 0..<count {
            let left  = i < lhsParts.count ? lhsParts[i] : "0"
            let right = i < rhsParts.count ? rhsParts[i] : "0"

            if let l = Int(left), let r = Int(right) {
                if l != r { return l > r }
            } else {
                if left != right { return left > right }
            }
        }

        // Cores are equal. A version with no pre-release is greater than
        // one with a pre-release. Both having pre-releases → lexicographic.
        switch (lhsPre, rhsPre) {
        case (nil, nil):
            return false // equal
        case (nil, _):
            return true   // lhs is release, rhs is pre-release → lhs > rhs
        case (_?, nil):
            return false  // lhs is pre-release, rhs is release → lhs < rhs
        case (let lhs?, let rhs?):
            return lhs > rhs
        }
    }
}
