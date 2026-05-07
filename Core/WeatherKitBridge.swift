#if AETHERDESK_STORE
import Foundation
import WeatherKit
import CoreLocation
import os.log

/// Intercepts `window.fetch` calls to `api.open-meteo.com` from wallpaper JS
/// and fulfils them with WeatherKit data, returning JSON in the same schema
/// WeatherAether already parses. Zero changes to the wallpaper HTML required.
///
/// Only compiled in `AETHERDESK_STORE` builds; the OSS build never references
/// this type. The AppStore build configuration sets a macOS 13 minimum, so no
/// `@available` guard is needed here.
final class WeatherKitBridge {

    static let shared = WeatherKitBridge()
    private let service = WeatherService.shared

    private init() {}

    // MARK: - Intercept check

    /// Returns true when the URL should be fulfilled by WeatherKit instead of
    /// being forwarded to URLSession. Only the forecast endpoint is intercepted;
    /// geocoding requests (geocoding-api.open-meteo.com) pass through normally.
    static func shouldIntercept(_ url: URL) -> Bool {
        url.host == "api.open-meteo.com"
    }

    // MARK: - Fetch

    /// Fetches weather via WeatherKit and calls `completion` with an
    /// (HTTP status, JSON body) pair formatted to match open-meteo's response
    /// schema. Runs the WeatherKit async call on a Swift concurrency Task.
    func fetch(url: URL, completion: @escaping (Int, String?) -> Void) {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let latStr = components.queryItems?.first(where: { $0.name == "latitude" })?.value,
            let lonStr = components.queryItems?.first(where: { $0.name == "longitude" })?.value,
            let lat = Double(latStr),
            let lon = Double(lonStr)
        else {
            Logger.app.warning("ÆtherDesk WeatherKitBridge: could not parse lat/lon from URL")
            completion(0, nil)
            return
        }

        let tempUnit  = components.queryItems?.first(where: { $0.name == "temperature_unit" })?.value ?? "celsius"
        let windUnit  = components.queryItems?.first(where: { $0.name == "wind_speed_unit" })?.value ?? "kmh"
        let location  = CLLocation(latitude: lat, longitude: lon)

        Task {
            do {
                let (current, hourly, daily) = try await service.weather(
                    for: location,
                    including: .current, .hourly, .daily
                )
                let json = self.buildJSON(
                    current: current,
                    hourly: hourly,
                    daily: daily,
                    tempUnit: tempUnit,
                    windUnit: windUnit
                )
                if let data = try? JSONSerialization.data(withJSONObject: json),
                   let body = String(data: data, encoding: .utf8) {
                    completion(200, body)
                } else {
                    completion(0, nil)
                }
            } catch {
                Logger.app.error("ÆtherDesk WeatherKitBridge: \(error.localizedDescription)")
                completion(0, nil)
            }
        }
    }

    // MARK: - JSON construction

    private func buildJSON(
        current: CurrentWeather,
        hourly: Forecast<HourWeather>,
        daily: Forecast<DayWeather>,
        tempUnit: String,
        windUnit: String
    ) -> [String: Any] {

        let useFahrenheit = (tempUnit == "fahrenheit")
        let useMPH        = (windUnit == "mph")

        func temp(_ m: Measurement<UnitTemperature>) -> Double {
            let v = useFahrenheit
                ? m.converted(to: .fahrenheit).value
                : m.converted(to: .celsius).value
            return (v * 10).rounded() / 10
        }

        func wind(_ m: Measurement<UnitSpeed>) -> Double {
            let v = useMPH
                ? m.converted(to: .milesPerHour).value
                : m.converted(to: .kilometersPerHour).value
            return (v * 10).rounded() / 10
        }

        let iso      = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let dateFmt  = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"
        dateFmt.timeZone   = TimeZone(identifier: "UTC")

        // Current conditions
        let currentDict: [String: Any] = [
            "temperature_2m":        temp(current.temperature),
            "apparent_temperature":  temp(current.apparentTemperature),
            "relative_humidity_2m":  Int((current.humidity * 100).rounded()),
            "wind_speed_10m":        wind(current.wind.speed),
            "weathercode":           wmoCode(for: current.condition),
            "is_day":                current.isDaylight ? 1 : 0,
            "uv_index":              current.uvIndex.value,
        ]

        // Hourly — next 24 hours
        let hours = Array(hourly.prefix(24))
        let hourlyDict: [String: Any] = [
            "time":                      hours.map { iso.string(from: $0.date) },
            "temperature_2m":            hours.map { temp($0.temperature) },
            "weathercode":               hours.map { wmoCode(for: $0.condition) },
            "precipitation_probability": hours.map { Int(($0.precipitationChance * 100).rounded()) },
        ]

        // Daily — next 7 days
        let days = Array(daily.prefix(7))
        let dailyDict: [String: Any] = [
            "time":              days.map { dateFmt.string(from: $0.date) },
            "temperature_2m_max": days.map { temp($0.highTemperature) },
            "temperature_2m_min": days.map { temp($0.lowTemperature) },
            "weathercode":        days.map { wmoCode(for: $0.condition) },
            "sunrise":            days.map { iso.string(from: $0.sun.sunrise ?? $0.date) },
            "sunset":             days.map { iso.string(from: $0.sun.sunset  ?? $0.date) },
        ]

        return [
            "current": currentDict,
            "hourly":  hourlyDict,
            "daily":   dailyDict,
        ]
    }

    // MARK: - WeatherCondition → WMO code

    /// Maps WeatherKit's `WeatherCondition` to the WMO weather interpretation
    /// codes that open-meteo uses and that WeatherAether's JS already parses.
    private func wmoCode(for condition: WeatherCondition) -> Int {
        switch condition {
        case .clear:                                    return 0   // clear sky
        case .mostlyClear:                             return 1   // mainly clear
        case .partlyCloudy:                            return 2   // partly cloudy
        case .mostlyCloudy, .cloudy:                   return 3   // overcast
        case .foggy:                                   return 45  // fog
        case .haze, .smoky:                            return 4   // smoke/haze
        case .blowingDust:                             return 7   // dust
        case .drizzle:                                 return 51  // light drizzle
        case .freezingDrizzle:                         return 56  // light freezing drizzle
        case .rain:                                    return 61  // slight rain
        case .heavyRain:                               return 63  // moderate rain
        case .freezingRain:                            return 66  // light freezing rain
        case .wintryMix:                               return 68  // slight sleet
        case .flurries, .blowingSnow, .sunFlurries:   return 71  // slight snow fall
        case .snow:                                    return 73  // moderate snow fall
        case .heavySnow, .blizzard:                    return 75  // heavy snow fall
        case .sleet:                                   return 77  // snow grains
        case .sunShowers:                              return 80  // slight rain showers
        case .hail:                                    return 96  // thunderstorm + hail
        case .isolatedThunderstorms,
             .scatteredThunderstorms,
             .thunderstorms:                           return 95  // thunderstorm
        case .strongStorms:                            return 99  // thunderstorm + heavy hail
        case .tropicalStorm, .hurricane:               return 99
        case .breezy, .windy,
             .hot, .frigid:                            return 1   // no direct WMO equivalent
        @unknown default:                              return 0
        }
    }
}
#endif
