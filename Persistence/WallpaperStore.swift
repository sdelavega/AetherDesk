import Foundation

class WallpaperStore {

    private let userDefaults = UserDefaults.standard
    private let key = "AetherDesk.wallpaperStore"

    struct StoredWallpaper: Codable {
        let bundleID: UUID
        let name: String
        let path: String
        let displayAssignments: [String: UUID]
        let createdAt: Date
        let lastUsedAt: Date
    }

    func save(_ wallpaper: StoredWallpaper) {
        var wallpapers = loadAll()
        wallpapers[wallpaper.bundleID] = wallpaper
        saveAll(wallpapers)
    }

    func loadAll() -> [UUID: StoredWallpaper] {
        guard let data = userDefaults.data(forKey: key),
              let wallpapers = try? JSONDecoder().decode([UUID: StoredWallpaper].self, from: data) else {
            return [:]
        }
        return wallpapers
    }

    func delete(bundleID: UUID) {
        var wallpapers = loadAll()
        wallpapers.removeValue(forKey: bundleID)
        saveAll(wallpapers)
    }

    private func saveAll(_ wallpapers: [UUID: StoredWallpaper]) {
        if let data = try? JSONEncoder().encode(wallpapers) {
            userDefaults.set(data, forKey: key)
        }
    }

    func getMostRecent() -> StoredWallpaper? {
        return loadAll().values.sorted { $0.lastUsedAt > $1.lastUsedAt }.first
    }
}
