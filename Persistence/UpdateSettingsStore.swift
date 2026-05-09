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

struct UpdateSettings: Codable, Equatable {
    var automaticallyCheckForUpdates: Bool
    var automaticallyInstallUpdates: Bool
    /// Version string (e.g. "1.0.7") the user last chose to skip.
    /// Quiet checks suppress this release; interactive checks always show it.
    var skippedVersion: String?

    static let defaults = UpdateSettings(
        automaticallyCheckForUpdates: true,
        automaticallyInstallUpdates: false,
        skippedVersion: nil
    )
}

final class UpdateSettingsStore {

    static let shared = UpdateSettingsStore()

    static let settingsDidChange = Notification.Name("ÆtherDesk.updateSettingsDidChange")

    private let userDefaults: UserDefaults
    private let key = "AetherDesk.updateSettings.v1"
    private var cache: UpdateSettings?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> UpdateSettings {
        if let cache { return cache }
        guard let data = userDefaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(UpdateSettings.self, from: data) else {
            cache = .defaults
            return .defaults
        }
        cache = settings
        return settings
    }

    func save(_ settings: UpdateSettings) {
        cache = settings
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: key)
        NotificationCenter.default.post(name: Self.settingsDidChange, object: settings)
    }

    func invalidateCache() { cache = nil }
}
