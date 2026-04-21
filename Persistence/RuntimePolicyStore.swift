import Foundation

/// Runtime constraints produced by import validation and consumed by wallpaper
/// runtimes. Bundled wallpapers and older imports default to the unrestricted
/// policy, which preserves existing behavior.
struct WallpaperRuntimePolicy: Codable, Equatable {
    let fpsCap: Int
    let networkBudgetPerMinute: Int?
    let warnings: [String]

    static let unrestricted = WallpaperRuntimePolicy(
        fpsCap: Constants.Defaults.fpsCap,
        networkBudgetPerMinute: nil,
        warnings: []
    )

    init(fpsCap: Int, networkBudgetPerMinute: Int?, warnings: [String]) {
        self.fpsCap = min(Constants.Defaults.maxFPS,
                          max(Constants.Defaults.minFPS, fpsCap))
        self.networkBudgetPerMinute = networkBudgetPerMinute.map { max(0, $0) }
        self.warnings = warnings
    }

    init(classification: WallpaperClassification) {
        switch classification {
        case .allowed:
            self = .unrestricted
        case .allowedWithLimits(let fps, let networkBudget, let warnings):
            self.init(fpsCap: fps,
                      networkBudgetPerMinute: networkBudget,
                      warnings: warnings)
        case .rejected:
            self = .unrestricted
        }
    }
}

final class RuntimePolicyStore {

    static let shared = RuntimePolicyStore()

    private let userDefaults: UserDefaults
    private let key = "AetherDesk.runtimePolicyStore.v1"
    private var cache: [String: WallpaperRuntimePolicy]?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func save(_ policy: WallpaperRuntimePolicy, for bundleID: UUID) {
        var policies = loadAll()
        policies[bundleID.uuidString] = policy
        saveAll(policies)
    }

    func load(for bundleID: UUID) -> WallpaperRuntimePolicy {
        loadAll()[bundleID.uuidString] ?? .unrestricted
    }

    func delete(for bundleID: UUID) {
        var policies = loadAll()
        policies.removeValue(forKey: bundleID.uuidString)
        saveAll(policies)
    }

    func invalidateCache() {
        cache = nil
    }

    private func loadAll() -> [String: WallpaperRuntimePolicy] {
        if let cache { return cache }
        guard let data = userDefaults.data(forKey: key),
              let policies = try? JSONDecoder().decode([String: WallpaperRuntimePolicy].self, from: data) else {
            cache = [:]
            return [:]
        }
        cache = policies
        return policies
    }

    private func saveAll(_ policies: [String: WallpaperRuntimePolicy]) {
        cache = policies
        guard let data = try? JSONEncoder().encode(policies) else { return }
        userDefaults.set(data, forKey: key)
    }
}
