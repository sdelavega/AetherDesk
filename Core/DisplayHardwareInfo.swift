// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega
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

import ColorSync
import CoreGraphics
import Foundation

struct DisplayHardwareInfo: Equatable {
    let displayID: CGDirectDisplayID
    let uuid: String?
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    /// Quartz global display coordinates: origin at the main display's top-left, y increasing down.
    let frame: CGRect

    static func live(_ id: CGDirectDisplayID, frame: CGRect) -> DisplayHardwareInfo {
        let uuid = CGDisplayCreateUUIDFromDisplayID(id).map {
            CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
        }
        return DisplayHardwareInfo(displayID: id, uuid: uuid,
                                   vendor: CGDisplayVendorNumber(id),
                                   model: CGDisplayModelNumber(id),
                                   serial: CGDisplaySerialNumber(id), frame: frame)
    }
}
