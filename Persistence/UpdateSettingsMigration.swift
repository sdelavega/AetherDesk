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

protocol UpdaterPreferences: AnyObject {
    var automaticallyChecks: Bool { get set }
    var automaticallyDownloads: Bool { get set }
}

enum UpdateSettingsMigration {
    private struct LegacySettings: Decodable {
        let automaticallyCheckForUpdates: Bool
        let automaticallyInstallUpdates: Bool
        let skippedVersion: String?
    }

    static func migrate(defaults: UserDefaults, into prefs: UpdaterPreferences) {
        let migratedKey = "AetherDesk.updateSettingsMigrated"
        guard !defaults.bool(forKey: migratedKey) else { return }
        let legacyKey = "AetherDesk.updateSettings.v1"
        if let data = defaults.data(forKey: legacyKey),
           let settings = try? JSONDecoder().decode(LegacySettings.self, from: data) {
            prefs.automaticallyChecks = settings.automaticallyCheckForUpdates
            prefs.automaticallyDownloads = settings.automaticallyInstallUpdates
            defaults.removeObject(forKey: legacyKey)
        }
        defaults.set(true, forKey: migratedKey)
    }
}
