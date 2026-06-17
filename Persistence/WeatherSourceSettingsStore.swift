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

#if AETHERDESK_STORE
import Foundation

/// User's preference for which weather data source the App Store build's
/// WeatherAether wallpaper should use. Only meaningful in `AETHERDESK_STORE`
/// builds — the OSS build never references WeatherKit and always uses
/// Open-Meteo directly, so this store and its UI control don't exist there.
enum WeatherDataSourcePreference: String, Codable {
    /// Try Apple Weather (WeatherKit) first; silently fall back to Open-Meteo
    /// if WeatherKit is unavailable or errors. This is the default.
    case automatic
    /// Always use Open-Meteo; never attempt WeatherKit.
    case openMeteoOnly
}

final class WeatherSourceSettingsStore {

    static let shared = WeatherSourceSettingsStore()

    static let settingsDidChange = Notification.Name("ÆtherDesk.weatherSourceSettingsDidChange")

    private let userDefaults: UserDefaults
    private let key = "AetherDesk.weatherSourcePreference.v1"
    private var cache: WeatherDataSourcePreference?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> WeatherDataSourcePreference {
        if let cache { return cache }
        guard let raw = userDefaults.string(forKey: key),
              let preference = WeatherDataSourcePreference(rawValue: raw) else {
            cache = .automatic
            return .automatic
        }
        cache = preference
        return preference
    }

    func save(_ preference: WeatherDataSourcePreference) {
        cache = preference
        userDefaults.set(preference.rawValue, forKey: key)
        NotificationCenter.default.post(name: Self.settingsDidChange, object: preference)
    }

    func invalidateCache() { cache = nil }
}
#endif
