import AppKit
import Foundation

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screenNumber = deviceDescription[key] as? NSNumber
        return screenNumber?.uint32Value ?? 0
    }
}
