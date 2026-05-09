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

import Testing
import Foundation

@Suite("PropertyStore") struct PropertyStoreTests {
    let store: PropertyStore

    init() {
        let defaults = UserDefaults(suiteName: "AetherDeskTests.\(UUID().uuidString)")!
        store = PropertyStore(userDefaults: defaults)
    }

    @Test func saveAndLoad() {
        let id = UUID()
        store.save(["speed": 42, "color": "#ff0000"], for: id)
        let props = store.load(for: id)
        #expect(props["speed"] as? Int == 42)
        #expect(props["color"] as? String == "#ff0000")
    }

    @Test func loadMissingBundleReturnsEmpty() {
        #expect(store.load(for: UUID()).isEmpty)
    }

    @Test func overwriteExistingProperties() {
        let id = UUID()
        store.save(["v": 1], for: id)
        store.save(["v": 2], for: id)
        #expect(store.load(for: id)["v"] as? Int == 2)
    }

    @Test func deleteRemovesEntry() {
        let id = UUID()
        store.save(["v": 1], for: id)
        store.delete(for: id)
        #expect(store.load(for: id).isEmpty)
    }

    @Test func deleteNonexistentIsNoop() {
        store.delete(for: UUID()) // should not crash
    }

    @Test func multipleBundlesAreIndependent() {
        let a = UUID(), b = UUID()
        store.save(["k": "a"], for: a)
        store.save(["k": "b"], for: b)
        #expect(store.load(for: a)["k"] as? String == "a")
        #expect(store.load(for: b)["k"] as? String == "b")
    }

    @Test func invalidateCacheThenReloadFromDefaults() {
        let id = UUID()
        store.save(["x": 99], for: id)
        store.invalidateCache()
        #expect(store.load(for: id)["x"] as? Int == 99)
    }

    @Test func saveVariousValueTypes() {
        let id = UUID()
        store.save(["int": 1, "double": 3.14, "string": "hi", "bool": true], for: id)
        let props = store.load(for: id)
        #expect(props["int"] as? Int == 1)
        #expect(props["string"] as? String == "hi")
        #expect(props["bool"] as? Bool == true)
    }
}
