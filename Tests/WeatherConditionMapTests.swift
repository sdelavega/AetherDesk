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
import WeatherKit

@Suite("Weather condition matrix")
struct WeatherConditionMapTests {
    private struct Matrix: Decodable {
        struct Condition: Decodable {
            let raw: String
            let code: Int
            let state: String
        }
        let wmo: [String: String]
        let conditions: [Condition]
    }

    @Test func everyWeatherKitConditionMatchesSharedMatrix() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("JS/condition-matrix.json")
        let matrix = try JSONDecoder().decode(Matrix.self, from: Data(contentsOf: fixture))
        let rawValues = matrix.conditions.map(\.raw)
        // Pin both the SDK's exhaustive case list and the actual raw strings.
        #expect(Set(rawValues) == Set(WeatherCondition.allCases.map(\.rawValue)))
        #expect(Set(rawValues).count == rawValues.count)
        for condition in matrix.conditions {
            let code = WeatherConditionMap.wmoCode(forRawCondition: condition.raw)
            #expect(code == condition.code, "\(condition.raw) must preserve WMO \(condition.code)")
            #expect(matrix.wmo[String(code)] == condition.state, "\(condition.raw) must select \(condition.state)")
        }
    }

    @Test(arguments: ["", "unknown", "futureWeatherCondition", "Clear", "RAIN"])
    func unknownConditionsUseClearFallback(raw: String) {
        #expect(WeatherConditionMap.wmoCode(forRawCondition: raw) == 0)
    }
}
