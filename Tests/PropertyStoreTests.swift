import Testing
import Foundation

@Suite("PropertyStore") struct PropertyStoreTests {
    let store: PropertyStore

    init() {
        let defaults = UserDefaults(suiteName: "AetherDeskTests.\(UUID().uuidString)")!
        store = PropertyStore(userDefaults: defaults)
    }

    @Test func saveAndLoad() {
        let id = UUID()
        store.save(["speed": 42, "color": "#ff0000"], for: id)
        let props = store.load(for: id)
        #expect(props["speed"] as? Int == 42)
        #expect(props["color"] as? String == "#ff0000")
    }

    @Test func loadMissingBundleReturnsEmpty() {
        #expect(store.load(for: UUID()).isEmpty)
    }

    @Test func overwriteExistingProperties() {
        let id = UUID()
        store.save(["v": 1], for: id)
        store.save(["v": 2], for: id)
        #expect(store.load(for: id)["v"] as? Int == 2)
    }

    @Test func deleteRemovesEntry() {
        let id = UUID()
        store.save(["v": 1], for: id)
        store.delete(for: id)
        #expect(store.load(for: id).isEmpty)
    }

    @Test func deleteNonexistentIsNoop() {
        store.delete(for: UUID()) // should not crash
    }

    @Test func multipleBundlesAreIndependent() {
        let a = UUID(), b = UUID()
        store.save(["k": "a"], for: a)
        store.save(["k": "b"], for: b)
        #expect(store.load(for: a)["k"] as? String == "a")
        #expect(store.load(for: b)["k"] as? String == "b")
    }

    @Test func invalidateCacheThenReloadFromDefaults() {
        let id = UUID()
        store.save(["x": 99], for: id)
        store.invalidateCache()
        #expect(store.load(for: id)["x"] as? Int == 99)
    }

    @Test func saveVariousValueTypes() {
        let id = UUID()
        store.save(["int": 1, "double": 3.14, "string": "hi", "bool": true], for: id)
        let props = store.load(for: id)
        #expect(props["int"] as? Int == 1)
        #expect(props["string"] as? String == "hi")
        #expect(props["bool"] as? Bool == true)
    }
}
