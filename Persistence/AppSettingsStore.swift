import Foundation

struct PerformanceSettings: Codable, Equatable {
    var fpsCap: Int
    var respectLowPowerMode: Bool
    var pauseWhenNotVisible: Bool
    var pauseOnBatteryPower: Bool
    var blockExternalNetwork: Bool

    static let defaults = PerformanceSettings(
        fpsCap: Constants.Defaults.fpsCap,
        respectLowPowerMode: true,
        pauseWhenNotVisible: true,
        pauseOnBatteryPower: false,
        blockExternalNetwork: false
    )

    var clampedFPSCap: Int {
        min(Constants.Defaults.maxFPS, max(Constants.Defaults.minFPS, fpsCap))
    }
}

final class AppSettingsStore {

    static let shared = AppSettingsStore()

    static let performanceSettingsDidChange =
        Notification.Name("ÆtherDesk.performanceSettingsDidChange")

    private let userDefaults: UserDefaults
    private let key = "AetherDesk.performanceSettings.v1"
    private var cache: PerformanceSettings?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func loadPerformanceSettings() -> PerformanceSettings {
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
            blockExternalNetwork: settings.blockExternalNetwork
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
            blockExternalNetwork: settings.blockExternalNetwork
        )
        cache = normalized
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        userDefaults.set(data, forKey: key)
        NotificationCenter.default.post(
            name: Self.performanceSettingsDidChange,
            object: normalized
        )
    }

    func invalidateCache() {
        cache = nil
    }
}
