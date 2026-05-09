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

class DisplayManager {

    private(set) var displayIDs: [CGDirectDisplayID] = []
    private(set) var screens: [CGDirectDisplayID: NSScreen] = [:]

    init() {
        updateDisplayList()
    }

    func updateDisplayList() {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)

        displayIDs = Array(displays.prefix(Int(displayCount)))
        screens = [:]

        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                let displayID = CGDirectDisplayID(number.uint32Value)
                screens[displayID] = screen
            }
        }

        if screens.isEmpty {
            for (index, displayID) in displayIDs.enumerated() {
                if index < NSScreen.screens.count {
                    screens[displayID] = NSScreen.screens[index]
                }
            }
        }
    }

    func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens[displayID]
    }

    func isPrimaryDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        return CGDisplayIsMain(displayID) != 0
    }

    func displayCount() -> Int {
        return displayIDs.count
    }
}
