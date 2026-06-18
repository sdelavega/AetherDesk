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

import AppKit
import Foundation

struct DisplayIdentity: Hashable, Codable, CustomStringConvertible {
    let key: String

    var description: String { key }

    static func forDisplay(_ displayID: CGDirectDisplayID) -> DisplayIdentity {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)

        // When the display reports real hardware identifiers, use them.
        // But if serial is 0 (common with identical external displays),
        // append the CGDirectDisplayID to prevent identity collisions.
        if vendor != 0 || model != 0 {
            if serial != 0 {
                return DisplayIdentity(key: "display:\(vendor):\(model):\(serial)")
            } else {
                return DisplayIdentity(key: "display:\(vendor):\(model):cgd:\(displayID)")
            }
        }
        return legacy(displayID)
    }

    static func legacy(_ displayID: CGDirectDisplayID) -> DisplayIdentity {
        DisplayIdentity(key: "cgdisplay:\(displayID)")
    }

    static func legacyNumeric(_ displayID: CGDirectDisplayID) -> String {
        String(displayID)
    }
}
