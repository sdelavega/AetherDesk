import Testing
import Foundation

@Suite("UpdateSettingsStore") struct UpdateSettingsStoreTests {
    let store: UpdateSettingsStore

    init() {
        let defaults = UserDefaults(suiteName: "AetherDeskTests.\(UUID().uuidString)")!
        store = UpdateSettingsStore(userDefaults: defaults)
    }

    @Test func defaultsCheckOnInstallOff() {
        let s = store.load()
        #expect(s.automaticallyCheckForUpdates == true)
        #expect(s.automaticallyInstallUpdates == false)
        #expect(s.skippedVersion == nil)
    }

    @Test func saveAndLoad() {
        var s = UpdateSettings.defaults
        s.automaticallyInstallUpdates = true
        s.skippedVersion = "2.0.0"
        store.save(s)
        let loaded = store.load()
        #expect(loaded.automaticallyInstallUpdates == true)
        #expect(loaded.skippedVersion == "2.0.0")
    }

    @Test func skippedVersionClearedOnSave() {
        var s = UpdateSettings.defaults
        s.skippedVersion = "1.5.0"
        store.save(s)
        s.skippedVersion = nil
        store.save(s)
        #expect(store.load().skippedVersion == nil)
    }

    @Test func invalidateCacheThenReloadFromDefaults() {
        var s = UpdateSettings.defaults
        s.automaticallyInstallUpdates = true
        store.save(s)
        store.invalidateCache()
        #expect(store.load().automaticallyInstallUpdates == true)
    }
}
