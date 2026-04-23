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
