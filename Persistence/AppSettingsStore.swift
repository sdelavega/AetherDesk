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

struct PerformanceSettings: Codable, Equatable {
    var fpsCap: Int
    var respectLowPowerMode: Bool
    var pauseWhenNotVisible: Bool
    var pauseOnBatteryPower: Bool
    var blockExternalNetwork: Bool
    var allowLANAccess: Bool

    static let defaults = PerformanceSettings(
        fpsCap: Constants.Defaults.fpsCap,
        respectLowPowerMode: true,
        pauseWhenNotVisible: true,
        pauseOnBatteryPower: false,
        blockExternalNetwork: false,
        allowLANAccess: false
    )

    var clampedFPSCap: Int {
        min(Constants.Defaults.maxFPS, max(Constants.Defaults.minFPS, fpsCap))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fpsCap = try container.decodeIfPresent(Int.self, forKey: .fpsCap) ?? Constants.Defaults.fpsCap
        respectLowPowerMode = try container.decodeIfPresent(Bool.self, forKey: .respectLowPowerMode) ?? true
        pauseWhenNotVisible = try container.decodeIfPresent(Bool.self, forKey: .pauseWhenNotVisible) ?? true
        pauseOnBatteryPower = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBatteryPower) ?? false
        blockExternalNetwork = try container.decodeIfPresent(Bool.self, forKey: .blockExternalNetwork) ?? false
        allowLANAccess = try container.decodeIfPresent(Bool.self, forKey: .allowLANAccess) ?? false
    }

    init(fpsCap: Int, respectLowPowerMode: Bool, pauseWhenNotVisible: Bool,
         pauseOnBatteryPower: Bool, blockExternalNetwork: Bool, allowLANAccess: Bool) {
        self.fpsCap = fpsCap
        self.respectLowPowerMode = respectLowPowerMode
        self.pauseWhenNotVisible = pauseWhenNotVisible
        self.pauseOnBatteryPower = pauseOnBatteryPower
        self.blockExternalNetwork = blockExternalNetwork
        self.allowLANAccess = allowLANAccess
    }
}

final class AppSettingsStore {

    static let shared = AppSettingsStore()

    static let performanceSettingsDidChange =
        Notification.Name("ÆtherDesk.performanceSettingsDidChange")

    private let userDefaults: UserDefaults
    private let key = "AetherDesk.performanceSettings.v1"
    private var cache: PerformanceSettings?
    private let cacheLock = NSLock()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadPerformanceSettings() -> PerformanceSettings {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cache { return cache }
        guard let data = userDefaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(PerformanceSettings.self, from: data) else {
            cache = .defaults
            return .defaults
        }
        let normalized = PerformanceSettings(
            fpsCap: settings.clampedFPSCap,
            respectLowPowerMode: settings.respectLowPowerMode,
            pauseWhenNotVisible: settings.pauseWhenNotVisible,
            pauseOnBatteryPower: settings.pauseOnBatteryPower,
            blockExternalNetwork: settings.blockExternalNetwork,
            allowLANAccess: settings.allowLANAccess
        )
        cache = normalized
        return normalized
    }

    func savePerformanceSettings(_ settings: PerformanceSettings) {
        let normalized = PerformanceSettings(
            fpsCap: settings.clampedFPSCap,
            respectLowPowerMode: settings.respectLowPowerMode,
            pauseWhenNotVisible: settings.pauseWhenNotVisible,
            pauseOnBatteryPower: settings.pauseOnBatteryPower,
            blockExternalNetwork: settings.blockExternalNetwork,
            allowLANAccess: settings.allowLANAccess
        )
        cacheLock.lock()
        cache = normalized
        cacheLock.unlock()
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        userDefaults.set(data, forKey: key)
        NotificationCenter.default.post(
            name: Self.performanceSettingsDidChange,
            object: normalized
        )
    }

    func invalidateCache() {
        cacheLock.lock()
        cache = nil
        cacheLock.unlock()
    }
}
