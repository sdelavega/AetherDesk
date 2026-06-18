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

    func effectiveFPSCap(with settings: PerformanceSettings) -> Int {
        if networkBudgetPerMinute != nil || !warnings.isEmpty {
            return min(fpsCap, settings.clampedFPSCap)
        }
        return settings.clampedFPSCap
    }
}

final class RuntimePolicyStore {

    static let shared = RuntimePolicyStore()

    private let userDefaults: UserDefaults
    private let key = "AetherDesk.runtimePolicyStore.v1"
    private var cache: [String: WallpaperRuntimePolicy]?
    private let cacheLock = NSLock()

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
        cacheLock.lock()
        cache = nil
        cacheLock.unlock()
    }

    private func loadAll() -> [String: WallpaperRuntimePolicy] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
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
        cacheLock.lock()
        cache = policies
        cacheLock.unlock()
        guard let data = try? JSONEncoder().encode(policies) else { return }
        userDefaults.set(data, forKey: key)
    }
}
