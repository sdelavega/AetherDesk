import Foundation

class PropertyStore {

    private let userDefaults = UserDefaults.standard
    private let key = "AetherDesk.propertyStore"

    func save(_ properties: [String: Any], for bundleID: UUID) {
        var allProperties = loadAll()
        allProperties[bundleID.uuidString] = properties
        saveAll(allProperties)
    }

    func load(for bundleID: UUID) -> [String: Any] {
        let allProperties = loadAll()
        return allProperties[bundleID.uuidString] ?? [:]
    }

    func delete(for bundleID: UUID) {
        var allProperties = loadAll()
        allProperties.removeValue(forKey: bundleID.uuidString)
        saveAll(allProperties)
    }

    private func loadAll() -> [String: [String: Any]] {
        guard let data = userDefaults.data(forKey: key),
              let properties = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return [:]
        }
        return properties
    }

    private func saveAll(_ properties: [String: [String: Any]]) {
        if let data = try? JSONSerialization.data(withJSONObject: properties) {
            userDefaults.set(data, forKey: key)
        }
    }
}
