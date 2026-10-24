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
/// exposes it, with ordered fallback candidates for older saved assignments.
/// Legacy matches migrate to the primary identity during restore.
final class WallpaperStore {

    private let userDefaults: UserDefaults
    private let key = "AetherDesk.wallpaperStore.v2"
    private let cacheLock = NSLock()

    private struct Payload: Codable {
        var displayAssignments: [String: String]
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: Display assignments

    /// Persist the (display identity -> bundleID) mapping for a single display.
    func setAssignment(bundleID: UUID, for info: DisplayHardwareInfo, among all: [DisplayHardwareInfo]) {
        mutatePayload { payload in
            let candidates = DisplayIdentity.candidates(for: info, among: all)
            for candidate in candidates.dropFirst() {
                payload.displayAssignments.removeValue(forKey: candidate.key)
            }
            payload.displayAssignments[candidates[0].key] = bundleID.uuidString
        }
    }

    /// Remove the persisted assignment for a display (e.g. when the display
    /// is no longer connected or the wallpaper is uninstalled).
    func removeAssignment(for info: DisplayHardwareInfo, among all: [DisplayHardwareInfo]) {
        mutatePayload { payload in
            for candidate in DisplayIdentity.candidates(for: info, among: all) {
                payload.displayAssignments.removeValue(forKey: candidate.key)
            }
        }
    }

    /// Resolve the first valid identity candidate for each connected display.
    /// Legacy matches migrate to the primary identity during the same load.
    func loadAssignments(for displays: [DisplayHardwareInfo]) -> [CGDirectDisplayID: UUID] {
        mutatePayload { payload in
            let assignments = payload.displayAssignments
            var out: [CGDirectDisplayID: UUID] = [:]
            for info in displays {
                let candidates = DisplayIdentity.candidates(for: info, among: displays)
                let primary = candidates[0].key
                for candidate in candidates {
                    guard let value = assignments[candidate.key],
                          let bundleID = UUID(uuidString: value) else {
                        continue
                    }
                    out[info.displayID] = bundleID
                    if candidate.key != primary {
                        for fallback in candidates.dropFirst() {
                            payload.displayAssignments.removeValue(forKey: fallback.key)
                        }
                        payload.displayAssignments[primary] = bundleID.uuidString
                    }
                    break
                }
            }
            return out
        }
    }

    /// Remove any stored assignments that reference a bundle ID no longer in
    /// the supplied set (e.g. after the user deleted an imported wallpaper).
    func pruneMissing(knownBundleIDs: Set<UUID>) {
        mutatePayload { payload in
            payload.displayAssignments = payload.displayAssignments.filter { _, value in
                guard let uuid = UUID(uuidString: value) else { return false }
                return knownBundleIDs.contains(uuid)
            }
        }
    }

    // MARK: Internals

    private var cachedPayload: Payload?

    func invalidateCache() {
        cacheLock.lock()
        cachedPayload = nil
        cacheLock.unlock()
    }

    /// Keep reads, migration, cache updates and persistence in one transaction.
    private func mutatePayload<T>(_ body: (inout Payload) -> T) -> T {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        var payload: Payload
        if let cached = cachedPayload {
            payload = cached
        } else if let data = userDefaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode(Payload.self, from: data) {
            payload = decoded
        } else {
            payload = Payload(displayAssignments: [:])
        }
        let originalAssignments = payload.displayAssignments
        let result = body(&payload)
        cachedPayload = payload
        if payload.displayAssignments != originalAssignments,
           let data = try? JSONEncoder().encode(payload) {
            userDefaults.set(data, forKey: key)
        }
        return result
    }
}
