import AppKit
import Foundation

struct DisplayIdentity: Hashable, Codable, CustomStringConvertible {
    let key: String

    var description: String { key }

    static func forDisplay(_ displayID: CGDirectDisplayID) -> DisplayIdentity {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)

        if vendor != 0 || model != 0 || serial != 0 {
            return DisplayIdentity(key: "display:\(vendor):\(model):\(serial)")
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
