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
