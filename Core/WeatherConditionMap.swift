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

/// Provider-only distinctions fold into the shared WeatherAether visual states.
/// Raw strings match WeatherKit's SDK interface and are pinned by the tests.
enum WeatherConditionMap {
    static func wmoCode(forRawCondition raw: String) -> Int {
        switch raw {
        case "clear": return 0
        case "mostlyClear": return 1
        case "partlyCloudy": return 2
        case "mostlyCloudy", "cloudy": return 3
        case "foggy": return 45
        case "smoky": return 4
        case "haze": return 5
        case "blowingDust": return 7
        case "drizzle": return 51
        case "freezingDrizzle": return 56
        case "rain": return 61
        case "heavyRain": return 65
        case "freezingRain", "wintryMix", "sleet": return 66
        case "flurries", "blowingSnow", "sunFlurries": return 71
        case "snow": return 73
        case "heavySnow", "blizzard": return 75
        case "sunShowers": return 80
        case "hail": return 96
        case "isolatedThunderstorms", "scatteredThunderstorms", "thunderstorms",
             "strongStorms", "tropicalStorm", "hurricane": return 95
        case "breezy", "windy", "hot", "frigid": return 1
        default: return 0
        }
    }
}
