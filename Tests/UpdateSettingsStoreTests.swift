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

@Suite("UpdateSettingsStore") struct UpdateSettingsStoreTests {
    let store: UpdateSettingsStore

    init() {
        let defaults = UserDefaults(suiteName: "AetherDeskTests.\(UUID().uuidString)")!
        store = UpdateSettingsStore(userDefaults: defaults)
    }

    @Test func defaultsCheckOnInstallOff() {
        let s = store.load()
        #expect(s.automaticallyCheckForUpdates == true)
        #expect(s.automaticallyInstallUpdates == false)
        #expect(s.skippedVersion == nil)
    }

    @Test func saveAndLoad() {
        var s = UpdateSettings.defaults
        s.automaticallyInstallUpdates = true
        s.skippedVersion = "2.0.0"
        store.save(s)
        let loaded = store.load()
        #expect(loaded.automaticallyInstallUpdates == true)
        #expect(loaded.skippedVersion == "2.0.0")
    }

    @Test func skippedVersionClearedOnSave() {
        var s = UpdateSettings.defaults
        s.skippedVersion = "1.5.0"
        store.save(s)
        s.skippedVersion = nil
        store.save(s)
        #expect(store.load().skippedVersion == nil)
    }

    @Test func invalidateCacheThenReloadFromDefaults() {
        var s = UpdateSettings.defaults
        s.automaticallyInstallUpdates = true
        store.save(s)
        store.invalidateCache()
        #expect(store.load().automaticallyInstallUpdates == true)
    }
}
