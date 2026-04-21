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
