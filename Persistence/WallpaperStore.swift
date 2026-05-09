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
import AppKit

/// Persists the current per-display wallpaper assignment across launches.
///
/// Shape on disk (UserDefaults, JSON-encoded):
///   {
///     "displayAssignments": { "<displayIdentity>": "<bundleUUID>" }
///   }
///
/// Display identities prefer vendor/model/serial metadata when CoreGraphics
/// exposes it, falling back to CGDirectDisplayID for displays that do not
/// report stable hardware identifiers. Legacy numeric display-ID keys are read
/// during restore so older installs migrate naturally as assignments are saved.
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

    /// Persist the (display identity -> bundleID) mapping for a single display.
    func setAssignment(bundleID: UUID, for displayID: CGDirectDisplayID) {
        var payload = loadPayload()
        let identity = DisplayIdentity.forDisplay(displayID)
        payload.displayAssignments[identity.key] = bundleID.uuidString
        payload.displayAssignments.removeValue(forKey: DisplayIdentity.legacyNumeric(displayID))
        if identity != .legacy(displayID) {
            payload.displayAssignments.removeValue(forKey: DisplayIdentity.legacy(displayID).key)
        }
        save(payload)
    }

    /// Remove the persisted assignment for a display (e.g. when the display
    /// is no longer connected or the wallpaper is uninstalled).
    func removeAssignment(for displayID: CGDirectDisplayID) {
        var payload = loadPayload()
        payload.displayAssignments.removeValue(forKey: DisplayIdentity.forDisplay(displayID).key)
        payload.displayAssignments.removeValue(forKey: DisplayIdentity.legacy(displayID).key)
        payload.displayAssignments.removeValue(forKey: DisplayIdentity.legacyNumeric(displayID))
        save(payload)
    }

    /// Resolve saved assignments for currently connected displays. Values that
    /// fail to parse as UUIDs are silently dropped. Lookup order is stable
    /// identity, new CGDisplay fallback key, then legacy raw numeric key.
    func loadAssignments(for displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: UUID] {
        let payload = loadPayload()
        var out: [CGDirectDisplayID: UUID] = [:]
        for displayID in displayIDs {
            let candidateKeys = [
                DisplayIdentity.forDisplay(displayID).key,
                DisplayIdentity.legacy(displayID).key,
                DisplayIdentity.legacyNumeric(displayID)
            ]
            for key in candidateKeys {
                guard let value = payload.displayAssignments[key],
                      let bundleID = UUID(uuidString: value) else {
                    continue
                }
                out[displayID] = bundleID
                break
            }
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

    private var cachedPayload: Payload?

    func invalidateCache() {
        cachedPayload = nil
    }

    private func loadPayload() -> Payload {
        if let cached = cachedPayload { return cached }
        guard let data = userDefaults.data(forKey: key),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            let empty = Payload(displayAssignments: [:])
            cachedPayload = empty
            return empty
        }
        cachedPayload = payload
        return payload
    }

    private func save(_ payload: Payload) {
        cachedPayload = payload
        guard let data = try? JSONEncoder().encode(payload) else { return }
        userDefaults.set(data, forKey: key)
    }
}
