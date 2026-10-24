// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega.
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

    static func candidates(for info: DisplayHardwareInfo, among all: [DisplayHardwareInfo]) -> [DisplayIdentity] {
        var result: [DisplayIdentity] = []
        if let uuid = info.uuid {
            result.append(DisplayIdentity(key: "uuid:\(uuid)"))
        }
        if info.vendor != 0 || info.model != 0 {
            let prefix = "display:\(info.vendor):\(info.model)"
            if info.serial != 0 {
                result.append(DisplayIdentity(key: "\(prefix):\(info.serial)"))
            }
            var peers = all.filter { $0.vendor == info.vendor && $0.model == info.model }
            if !peers.contains(where: { $0.displayID == info.displayID }) {
                peers.append(info)
            }
            peers.sort {
                if $0.frame.origin.x != $1.frame.origin.x { return $0.frame.origin.x < $1.frame.origin.x }
                if $0.frame.origin.y != $1.frame.origin.y { return $0.frame.origin.y < $1.frame.origin.y }
                return $0.displayID < $1.displayID
            }
            let ordinal = peers.firstIndex { $0.displayID == info.displayID }!
            result.append(DisplayIdentity(key: "\(prefix):ord:\(ordinal)"))
            if info.serial == 0 {
                result.append(DisplayIdentity(key: "\(prefix):cgd:\(info.displayID)"))
            }
        }
        result.append(legacy(info.displayID))
        result.append(DisplayIdentity(key: legacyNumeric(info.displayID)))
        return result
    }

    static func primary(for info: DisplayHardwareInfo, among all: [DisplayHardwareInfo]) -> DisplayIdentity {
        candidates(for: info, among: all).first!
    }

    static func legacy(_ displayID: CGDirectDisplayID) -> DisplayIdentity {
        DisplayIdentity(key: "cgdisplay:\(displayID)")
    }

    static func legacyNumeric(_ displayID: CGDirectDisplayID) -> String {
        String(displayID)
    }
}
