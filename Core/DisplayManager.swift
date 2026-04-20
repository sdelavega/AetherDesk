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
        if let screen = screens[displayID] {
            return screen
        }

        if let primaryScreen = NSScreen.screens.first {
            screens[displayID] = primaryScreen
            return primaryScreen
        }

        return nil
    }

    func isPrimaryDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        return CGDisplayIsMain(displayID) != 0
    }

    func displayCount() -> Int {
        return displayIDs.count
    }
}
