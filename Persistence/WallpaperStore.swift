import Foundation
import AppKit

/// Persists the current per-display wallpaper assignment across launches.
///
/// Shape on disk (UserDefaults, JSON-encoded):
///   {
///     "displayAssignments": { "<displayID>": "<bundleUUID>" }
///   }
///
/// Why keyed by stringified display ID: CGDirectDisplayID is not stable across
/// every kind of hardware change (a monitor unplugged & replugged can get a
/// new ID), but for the common case of the same configuration between runs
/// the ID is stable and cheap. When a saved ID no longer exists we simply
/// fall back to the provided default bundle for that display.
final class WallpaperStore {

    private let userDefaults: UserDefaults
    private let key = "AetherDesk.wallpaperStore.v2"

    private struct Payload: Codable {
        var displayAssignments: [String: String]
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: Display assignments

    /// Persist the (displayID -> bundleID) mapping for a single display.
    func setAssignment(bundleID: UUID, for displayID: CGDirectDisplayID) {
        var payload = loadPayload()
        payload.displayAssignments[String(displayID)] = bundleID.uuidString
        save(payload)
    }

    /// Remove the persisted assignment for a display (e.g. when the display
    /// is no longer connected or the wallpaper is uninstalled).
    func removeAssignment(for displayID: CGDirectDisplayID) {
        var payload = loadPayload()
        payload.displayAssignments.removeValue(forKey: String(displayID))
        save(payload)
    }

    /// Load every known (displayID -> bundleID) assignment. Values that fail
    /// to parse as UUIDs are silently dropped.
    func loadAssignments() -> [CGDirectDisplayID: UUID] {
        let payload = loadPayload()
        var out: [CGDirectDisplayID: UUID] = [:]
        for (k, v) in payload.displayAssignments {
            guard let displayID = UInt32(k),
                  let bundleID = UUID(uuidString: v)
            else { continue }
            out[CGDirectDisplayID(displayID)] = bundleID
        }
        return out
    }

    /// Remove any stored assignments that reference a bundle ID no longer in
    /// the supplied set (e.g. after the user deleted an imported wallpaper).
    func pruneMissing(knownBundleIDs: Set<UUID>) {
        var payload = loadPayload()
        payload.displayAssignments = payload.displayAssignments.filter { _, value in
            guard let uuid = UUID(uuidString: value) else { return false }
            return knownBundleIDs.contains(uuid)
        }
        save(payload)
    }

    // MARK: Internals

    private func loadPayload() -> Payload {
        guard let data = userDefaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return Payload(displayAssignments: [:]) }
        return payload
    }

    private func save(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: key)
    }
}
