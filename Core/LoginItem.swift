import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for toggling launch-at-login.
///
/// The API is only available on macOS 13+. On macOS 12 `LoginItem.isSupported`
/// is `false` and calling the setter is a no-op that throws
/// `LoginItemError.unsupported`, so the UI can disable the control with an
/// explanatory note.
enum LoginItem {

    /// Whether launch-at-login can actually be toggled on this macOS version.
    static var isSupported: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    /// Is the app currently registered to launch at login?
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// Register (or unregister) the app. Throws on macOS 12 or if the
    /// Service Management framework refuses.
    static func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw LoginItemError.unsupported
        }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
        } catch {
            throw LoginItemError.serviceFailed(underlying: error)
        }
    }

    /// User-facing description of the current state. Useful for tooltips /
    /// status labels in the UI.
    static var statusDescription: String {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:         return "Enabled"
            case .notRegistered:   return "Not enabled"
            case .notFound:        return "Not found"
            case .requiresApproval:
                return "Requires user approval in System Settings → Login Items"
            @unknown default:      return "Unknown"
            }
        }
        return "Unavailable (requires macOS 13 or later)"
    }
}

enum LoginItemError: Error, LocalizedError {
    case unsupported
    case serviceFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Launch at login requires macOS 13 or later."
        case .serviceFailed(let underlying):
            return "Could not update Launch at Login: \(underlying.localizedDescription)"
        }
    }
}
