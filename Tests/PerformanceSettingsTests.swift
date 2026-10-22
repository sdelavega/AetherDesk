// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega
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

@Suite struct PerformanceSettingsTests {
    @Test func freshInstallPausesOnBattery() {
        #expect(PerformanceSettings.defaults.pauseOnBatteryPower == true)
    }

    @Test func blobMissingKeyPausesOnBattery() throws {
        let data = Data(#"{"fpsCap":30}"#.utf8)
        let settings = try JSONDecoder().decode(PerformanceSettings.self, from: data)
        #expect(settings.pauseOnBatteryPower == true)
    }

    @Test func explicitFalseSurvives() throws {
        let data = Data(#"{"fpsCap":30,"respectLowPowerMode":true,"pauseWhenNotVisible":true,"pauseOnBatteryPower":false,"blockExternalNetwork":false,"allowLANAccess":false}"#.utf8)
        let settings = try JSONDecoder().decode(PerformanceSettings.self, from: data)
        #expect(settings.pauseOnBatteryPower == false)
    }

    @Test func storeWithoutDataReturnsDefaults() throws {
        let suiteName = "PerformanceSettingsTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(userDefaults: userDefaults)
        #expect(store.loadPerformanceSettings().pauseOnBatteryPower == true)
    }
}
