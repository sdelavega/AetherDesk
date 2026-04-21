import Testing
import AppKit

@Suite("WallpaperStore") struct WallpaperStoreTests {
    // Use a synthetic display ID that won't collide with real hardware.
    // CGDisplayVendorNumber(99999) returns 0 in a headless test environment,
    // so DisplayIdentity.forDisplay falls back to the cgdisplay: key form.
    let displayID: CGDirectDisplayID = 99999

    var store: WallpaperStore

    init() {
        let defaults = UserDefaults(suiteName: "AetherDeskTests.\(UUID().uuidString)")!
        store = WallpaperStore(userDefaults: defaults)
    }

    @Test func setAndLoadSingleAssignment() {
        let bundleID = UUID()
        store.setAssignment(bundleID: bundleID, for: displayID)
        let loaded = store.loadAssignments(for: [displayID])
        #expect(loaded[displayID] == bundleID)
    }

    @Test func updateAssignment() {
        let first = UUID(), second = UUID()
        store.setAssignment(bundleID: first, for: displayID)
        store.setAssignment(bundleID: second, for: displayID)
        #expect(store.loadAssignments(for: [displayID])[displayID] == second)
    }

    @Test func removeAssignment() {
        let bundleID = UUID()
        store.setAssignment(bundleID: bundleID, for: displayID)
        store.removeAssignment(for: displayID)
        #expect(store.loadAssignments(for: [displayID])[displayID] == nil)
    }

    @Test func unknownDisplayReturnsNil() {
        #expect(store.loadAssignments(for: [displayID])[displayID] == nil)
    }

    @Test func multipleDisplaysLoadedTogether() throws {
        // Synthetic display IDs may produce non-unique CG hardware identities on
        // a given machine, so seed the payload directly using legacy numeric keys
        // (the third fallback in loadAssignments) to guarantee distinct entries.
        let a: CGDirectDisplayID = 11111, b: CGDirectDisplayID = 22222
        let bundleA = UUID(), bundleB = UUID()
        let defaults = UserDefaults(suiteName: "AetherDeskTests.\(UUID().uuidString)")!
        let payload: [String: Any] = ["displayAssignments": [
            DisplayIdentity.legacyNumeric(a): bundleA.uuidString,
            DisplayIdentity.legacyNumeric(b): bundleB.uuidString
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: "AetherDesk.wallpaperStore.v2")
        let readStore = WallpaperStore(userDefaults: defaults)
        let loaded = readStore.loadAssignments(for: [a, b])
        #expect(loaded[a] == bundleA)
        #expect(loaded[b] == bundleB)
    }

    @Test func pruneMissingRemovesStaleEntries() throws {
        let keep = UUID(), remove = UUID()
        let displayA: CGDirectDisplayID = 33333, displayB: CGDirectDisplayID = 44444
        let defaults = UserDefaults(suiteName: "AetherDeskTests.\(UUID().uuidString)")!
        let payload: [String: Any] = ["displayAssignments": [
            DisplayIdentity.legacyNumeric(displayA): keep.uuidString,
            DisplayIdentity.legacyNumeric(displayB): remove.uuidString
        ]]
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: "AetherDesk.wallpaperStore.v2")
        let pruneStore = WallpaperStore(userDefaults: defaults)
        pruneStore.pruneMissing(knownBundleIDs: [keep])
        let loaded = pruneStore.loadAssignments(for: [displayA, displayB])
        #expect(loaded[displayA] == keep)
        #expect(loaded[displayB] == nil)
    }

    @Test func pruneMissingWithEmptySetClearsAll() {
        store.setAssignment(bundleID: UUID(), for: displayID)
        store.pruneMissing(knownBundleIDs: [])
        #expect(store.loadAssignments(for: [displayID])[displayID] == nil)
    }

    @Test func pruneMissingKeepsAllWhenAllKnown() {
        let bundleID = UUID()
        store.setAssignment(bundleID: bundleID, for: displayID)
        store.pruneMissing(knownBundleIDs: [bundleID])
        #expect(store.loadAssignments(for: [displayID])[displayID] == bundleID)
    }

    @Test func invalidateCacheThenReloadFromDefaults() {
        let bundleID = UUID()
        store.setAssignment(bundleID: bundleID, for: displayID)
        store.invalidateCache()
        #expect(store.loadAssignments(for: [displayID])[displayID] == bundleID)
    }

    @Test func legacyNumericKeyMigration() {
        // Seed a payload with a raw numeric key (legacy format from pre-DisplayIdentity)
        // and verify loadAssignments resolves it.
        let bundleID = UUID()
        let syntheticDisplay: CGDirectDisplayID = 55555
        let legacyKey = DisplayIdentity.legacyNumeric(syntheticDisplay)
        // Write the legacy key directly via a fresh store pointing at the same defaults
        let defaults = UserDefaults(suiteName: "AetherDeskTests.\(UUID().uuidString)")!
        let legacyPayload: [String: Any] = [
            "displayAssignments": [legacyKey: bundleID.uuidString]
        ]
        let data = try! JSONSerialization.data(withJSONObject: legacyPayload)
        // Re-encode in the Payload Codable shape the store expects
        struct Payload: Codable { var displayAssignments: [String: String] }
        let encoded = try! JSONEncoder().encode(Payload(displayAssignments: [legacyKey: bundleID.uuidString]))
        defaults.set(encoded, forKey: "AetherDesk.wallpaperStore.v2")
        let migratingStore = WallpaperStore(userDefaults: defaults)
        let loaded = migratingStore.loadAssignments(for: [syntheticDisplay])
        #expect(loaded[syntheticDisplay] == bundleID)
    }
}
