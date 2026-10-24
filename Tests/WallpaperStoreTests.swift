// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3 of the License.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Testing
import AppKit

@Suite("WallpaperStore") struct WallpaperStoreTests {
    private let key = "AetherDesk.wallpaperStore.v2"

    private func display(_ id: CGDirectDisplayID = 5, uuid: String? = "screen-uuid",
                         x: CGFloat = 0) -> DisplayHardwareInfo {
        DisplayHardwareInfo(displayID: id, uuid: uuid, vendor: 1, model: 2,
                            serial: 0, frame: CGRect(x: x, y: 0, width: 1920, height: 1080))
    }

    private func withStore(_ body: (WallpaperStore, UserDefaults) throws -> Void) rethrows {
        let suite = "AetherDeskTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(WallpaperStore(userDefaults: defaults), defaults)
    }

    private func seed(_ assignments: [String: String], in defaults: UserDefaults) throws {
        defaults.set(try JSONSerialization.data(withJSONObject: ["displayAssignments": assignments]),
                     forKey: key)
    }

    private func assignments(in defaults: UserDefaults) throws -> [String: String] {
        let data = try #require(defaults.data(forKey: key))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(payload["displayAssignments"] as? [String: String])
    }

    @Test func setAndUpdateAssignment() throws {
        try withStore { store, defaults in
            let info = display(), first = UUID(), second = UUID()
            let candidates = DisplayIdentity.candidates(for: info, among: [info])
            try seed(Dictionary(uniqueKeysWithValues: candidates.map { ($0.key, first.uuidString) }), in: defaults)
            store.setAssignment(bundleID: second, for: info, among: [info])
            #expect(store.loadAssignments(for: [info])[info.displayID] == second)
            #expect(try assignments(in: defaults) == ["uuid:screen-uuid": second.uuidString])
        }
    }

    @Test func removeAssignmentClearsEveryCandidate() throws {
        try withStore { store, defaults in
            let info = display(), other = display(6, uuid: "other")
            let all = [info, other], bundle = UUID()
            var values = Dictionary(uniqueKeysWithValues: DisplayIdentity.candidates(for: info, among: all).map { ($0.key, bundle.uuidString) })
            values["uuid:other"] = bundle.uuidString
            try seed(values, in: defaults)
            store.removeAssignment(for: info, among: all)
            #expect(store.loadAssignments(for: all)[info.displayID] == nil)
            #expect(try assignments(in: defaults) == ["uuid:other": bundle.uuidString])
        }
    }

    @Test func unknownDisplayReturnsNil() {
        withStore { store, _ in
            #expect(store.loadAssignments(for: [display()]).isEmpty)
        }
    }

    @Test(arguments: ["display:1:2:cgd:5", "5", "cgdisplay:5"])
    func legacyAssignmentMigratesOnce(legacyKey: String) throws {
        try withStore { store, defaults in
            let info = display(), bundle = UUID()
            try seed([legacyKey: bundle.uuidString], in: defaults)
            #expect(store.loadAssignments(for: [info])[5] == bundle)
            #expect(try assignments(in: defaults) == ["uuid:screen-uuid": bundle.uuidString])
            let migratedData = defaults.data(forKey: key)
            store.invalidateCache()
            #expect(store.loadAssignments(for: [info])[5] == bundle)
            #expect(defaults.data(forKey: key) == migratedData)
        }
    }

    @Test func firstValidCandidateWinsAndMigrates() throws {
        try withStore { store, defaults in
            let info = display(), bundle = UUID(), stale = UUID()
            try seed(["uuid:screen-uuid": "invalid", "display:1:2:ord:0": bundle.uuidString,
                      "display:1:2:cgd:5": stale.uuidString], in: defaults)
            #expect(store.loadAssignments(for: [info])[5] == bundle)
            #expect(try assignments(in: defaults) == ["uuid:screen-uuid": bundle.uuidString])
        }
    }

    @Test func primaryWinsOverLegacyAssignment() throws {
        try withStore { store, defaults in
            let info = display(), bundle = UUID()
            try seed(["uuid:screen-uuid": bundle.uuidString, "5": UUID().uuidString], in: defaults)
            #expect(store.loadAssignments(for: [info])[5] == bundle)
        }
    }

    @Test func twinsKeepPositionsWhenDisplayIDsSwap() throws {
        try withStore { store, defaults in
            let left = display(5, uuid: nil), right = display(6, uuid: nil, x: 1920)
            let a = UUID(), b = UUID()
            store.setAssignment(bundleID: a, for: left, among: [left, right])
            store.setAssignment(bundleID: b, for: right, among: [left, right])
            // Old CG display keys must not override the ordinal assignments.
            var values = try assignments(in: defaults)
            values["display:1:2:cgd:5"] = a.uuidString
            values["display:1:2:cgd:6"] = b.uuidString
            try seed(values, in: defaults)
            store.invalidateCache()
            let swappedLeft = display(6, uuid: nil), swappedRight = display(5, uuid: nil, x: 1920)
            let loaded = store.loadAssignments(for: [swappedRight, swappedLeft])
            #expect(loaded[swappedLeft.displayID] == a)
            #expect(loaded[swappedRight.displayID] == b)
        }
    }

    @Test func pruneMissingRemovesUnknownAndMalformedBundleIDs() throws {
        try withStore { store, defaults in
            let keep = UUID()
            try seed(["5": keep.uuidString, "6": UUID().uuidString, "7": "invalid"], in: defaults)
            store.pruneMissing(knownBundleIDs: [keep])
            #expect(try assignments(in: defaults) == ["5": keep.uuidString])
            #expect(store.loadAssignments(for: [display()])[5] == keep)
        }
    }

    @Test func pruneMissingWithEmptySetClearsAll() {
        withStore { store, _ in
            let info = display()
            store.setAssignment(bundleID: UUID(), for: info, among: [info])
            store.pruneMissing(knownBundleIDs: [])
            #expect(store.loadAssignments(for: [info]).isEmpty)
        }
    }

    @Test func concurrentSetsAndMigrationPreserveEveryAssignment() throws {
        try withStore { store, defaults in
            let displays = (0..<128).map { index in
                DisplayHardwareInfo(displayID: CGDirectDisplayID(index + 1),
                                    uuid: "screen-\(index)", vendor: UInt32(index + 1),
                                    model: 2, serial: 0,
                                    frame: CGRect(x: index * 1920, y: 0, width: 1920, height: 1080))
            }
            let bundles = displays.map { _ in UUID() }
            try seed(Dictionary(uniqueKeysWithValues: displays.map {
                (String($0.displayID), UUID().uuidString)
            }), in: defaults)

            DispatchQueue.concurrentPerform(iterations: displays.count * 2) { iteration in
                let index = (iteration / 2) % displays.count
                if iteration % 2 == 0 {
                    store.setAssignment(bundleID: bundles[index], for: displays[index], among: displays)
                } else {
                    _ = store.loadAssignments(for: displays)
                }
            }

            // Check the persisted payload as well as the in-memory result.
            store.invalidateCache()
            let loaded = store.loadAssignments(for: displays)
            #expect(loaded.count == displays.count)
            for (info, bundle) in zip(displays, bundles) {
                #expect(loaded[info.displayID] == bundle)
            }
            #expect(try assignments(in: defaults).count == displays.count)
        }
    }

    @Test func invalidateCacheThenReloadFromDefaults() {
        withStore { store, _ in
            let info = display(), bundle = UUID()
            store.setAssignment(bundleID: bundle, for: info, among: [info])
            store.invalidateCache()
            #expect(store.loadAssignments(for: [info])[5] == bundle)
        }
    }
}
