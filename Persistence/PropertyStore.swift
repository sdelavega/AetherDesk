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
import os.log

class PropertyStore {

    private let userDefaults: UserDefaults
    private let key = "AetherDesk.propertyStore"
    private var cache: [String: [String: Any]]?
    private let cacheLock = NSLock()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func save(_ properties: [String: Any], for bundleID: UUID) {
        var allProperties = loadAll()
        allProperties[bundleID.uuidString] = sanitize(properties)
        saveAll(allProperties)
    }

    func load(for bundleID: UUID) -> [String: Any] {
        let allProperties = loadAll()
        return sanitize(allProperties[bundleID.uuidString] ?? [:])
    }

    func delete(for bundleID: UUID) {
        var allProperties = loadAll()
        allProperties.removeValue(forKey: bundleID.uuidString)
        saveAll(allProperties)
    }

    func invalidateCache() {
        cacheLock.lock()
        cache = nil
        cacheLock.unlock()
    }

    private func loadAll() -> [String: [String: Any]] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache { return cached }
        guard let data = userDefaults.data(forKey: key),
              let properties = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            cache = [:]
            return [:]
        }
        cache = properties
        return properties
    }

    private func saveAll(_ properties: [String: [String: Any]]) {
        cacheLock.lock()
        cache = properties
        cacheLock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: properties) {
            userDefaults.set(data, forKey: key)
        }
    }

    private func sanitize(_ properties: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in properties {
            if isSafePropertyValue(value) {
                result[key] = value
            } else {
                Logger.app.warning("ÆtherDesk: rejected unsafe property value for key '\(key)' (type: \(String(describing: type(of: value))))")
            }
        }
        return result
    }

    private static let maxCollectionDepth = 5

    private func isSafePropertyValue(_ value: Any, depth: Int = 0) -> Bool {
        guard depth <= Self.maxCollectionDepth else {
            Logger.app.warning("ÆtherDesk: property exceeds maximum nesting depth")
            return false
        }
        switch value {
        case is String, is Bool, is Int, is Double, is Float:
            return true
        case let arr as [Any]:
            return arr.count <= 100 && arr.allSatisfy { isSafePropertyValue($0, depth: depth + 1) }
        case let dict as [String: Any]:
            return dict.count <= 100 && dict.values.allSatisfy { isSafePropertyValue($0, depth: depth + 1) }
        case is NSNull:
            return true
        default:
            return false
        }
    }
}
