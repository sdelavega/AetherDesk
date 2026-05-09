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

enum GeolocationPermission: String, Codable {
    case notDetermined
    case allowed
    case denied
}

final class GeolocationPermissionStore {

    static let shared = GeolocationPermissionStore()

    private let userDefaults: UserDefaults
    private let key = "AetherDesk.geolocationPermissions.v1"
    private var cache: [String: GeolocationPermission]?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load(for bundleID: UUID) -> GeolocationPermission {
        loadAll()[bundleID.uuidString] ?? .notDetermined
    }

    func save(_ permission: GeolocationPermission, for bundleID: UUID) {
        var all = loadAll()
        all[bundleID.uuidString] = permission
        saveAll(all)
    }

    func delete(for bundleID: UUID) {
        var all = loadAll()
        all.removeValue(forKey: bundleID.uuidString)
        saveAll(all)
    }

    func invalidateCache() {
        cache = nil
    }

    private func loadAll() -> [String: GeolocationPermission] {
        if let cache { return cache }
        guard let data = userDefaults.data(forKey: key),
              let permissions = try? JSONDecoder()
                .decode([String: GeolocationPermission].self, from: data) else {
            cache = [:]
            return [:]
        }
        cache = permissions
        return permissions
    }

    private func saveAll(_ permissions: [String: GeolocationPermission]) {
        cache = permissions
        guard let data = try? JSONEncoder().encode(permissions) else { return }
        userDefaults.set(data, forKey: key)
    }
}
