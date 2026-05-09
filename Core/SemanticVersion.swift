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
    static func compare(_ lhs: String, isGreaterThan rhs: String) -> Bool {
        let lhsParts = lhs.split(separator: ".").map(String.init)
        let rhsParts = rhs.split(separator: ".").map(String.init)
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
        return false // equal
    }
}
