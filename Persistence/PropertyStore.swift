import Foundation
import os.log

class PropertyStore {

    private let userDefaults: UserDefaults
    private let key = "AetherDesk.propertyStore"
    private var cache: [String: [String: Any]]?

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
        cache = nil
    }

    private func loadAll() -> [String: [String: Any]] {
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
        cache = properties
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

    private func isSafePropertyValue(_ value: Any) -> Bool {
        switch value {
        case is String, is Bool, is Int, is Double, is Float:
            return true
        case let arr as [Any]:
            return arr.count <= 100 && arr.allSatisfy { isSafePropertyValue($0) }
        case let dict as [String: Any]:
            return dict.count <= 100 && dict.values.allSatisfy { isSafePropertyValue($0) }
        case is NSNull:
            return true
        default:
            return false
        }
    }
}
