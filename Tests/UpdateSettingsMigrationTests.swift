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
import Testing

@Suite("UpdateSettingsMigration") struct UpdateSettingsMigrationTests {
    private final class Preferences: UpdaterPreferences {
        var automaticallyChecks = false
        var automaticallyDownloads = true
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "AetherDeskTests.UpdateMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func migratesV13JSONAndRemovesLegacyData() {
        withDefaults { defaults in
            let legacy = Data(#"{"automaticallyCheckForUpdates":true,"automaticallyInstallUpdates":false,"skippedVersion":"1.3.1"}"#.utf8)
            defaults.set(legacy, forKey: "AetherDesk.updateSettings.v1")
            let prefs = Preferences()
            UpdateSettingsMigration.migrate(defaults: defaults, into: prefs)
            #expect(prefs.automaticallyChecks)
            #expect(!prefs.automaticallyDownloads)
            #expect(defaults.object(forKey: "AetherDesk.updateSettings.v1") == nil)
            #expect(defaults.bool(forKey: "AetherDesk.updateSettingsMigrated"))
        }
    }

    @Test func secondRunPreservesChangedPreferencesAndLegacyData() {
        withDefaults { defaults in
            defaults.set(Data(#"{"automaticallyCheckForUpdates":true,"automaticallyInstallUpdates":false}"#.utf8), forKey: "AetherDesk.updateSettings.v1")
            let prefs = Preferences()
            UpdateSettingsMigration.migrate(defaults: defaults, into: prefs)
            prefs.automaticallyChecks = false
            prefs.automaticallyDownloads = true
            let laterData = Data(#"{"automaticallyCheckForUpdates":true,"automaticallyInstallUpdates":false}"#.utf8)
            defaults.set(laterData, forKey: "AetherDesk.updateSettings.v1")
            UpdateSettingsMigration.migrate(defaults: defaults, into: prefs)
            #expect(!prefs.automaticallyChecks)
            #expect(prefs.automaticallyDownloads)
            #expect(defaults.data(forKey: "AetherDesk.updateSettings.v1") == laterData)
        }
    }

    @Test func noLegacyDataPreservesPreferencesAndSetsFlag() {
        withDefaults { defaults in
            let prefs = Preferences()
            UpdateSettingsMigration.migrate(defaults: defaults, into: prefs)
            #expect(!prefs.automaticallyChecks)
            #expect(prefs.automaticallyDownloads)
            #expect(defaults.bool(forKey: "AetherDesk.updateSettingsMigrated"))
        }
    }

    @Test func migratesDisabledChecksAndEnabledDownloads() {
        withDefaults { defaults in
            defaults.set(Data(#"{"automaticallyCheckForUpdates":false,"automaticallyInstallUpdates":true}"#.utf8), forKey: "AetherDesk.updateSettings.v1")
            let prefs = Preferences()
            prefs.automaticallyChecks = true
            prefs.automaticallyDownloads = false
            UpdateSettingsMigration.migrate(defaults: defaults, into: prefs)
            #expect(!prefs.automaticallyChecks)
            #expect(prefs.automaticallyDownloads)
        }
    }

    @Test func malformedLegacyDataPreservesPreferences() {
        withDefaults { defaults in
            defaults.set(Data("invalid JSON".utf8), forKey: "AetherDesk.updateSettings.v1")
            let prefs = Preferences()
            UpdateSettingsMigration.migrate(defaults: defaults, into: prefs)
            #expect(!prefs.automaticallyChecks)
            #expect(prefs.automaticallyDownloads)
            #expect(defaults.data(forKey: "AetherDesk.updateSettings.v1") == Data("invalid JSON".utf8))
            #expect(defaults.bool(forKey: "AetherDesk.updateSettingsMigrated"))
        }
    }
}
