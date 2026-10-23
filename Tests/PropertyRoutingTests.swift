// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega
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

import AppKit
import Testing

@Suite(.serialized)
@MainActor
struct PropertyRoutingTests {
    @Test func bundleUpdatesReachEveryMatchingDisplayOnly() throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        fixture.install()

        fixture.manager.updateProperty("speed", value: 42, forBundleID: fixture.first.id)

        #expect(fixture.runtimes[101]?.updates == [.init(key: "speed", value: 42)])
        #expect(fixture.runtimes[202]?.updates == [.init(key: "speed", value: 42)])
        #expect(fixture.runtimes[303]?.updates.isEmpty == true)
        #expect(fixture.saved(for: fixture.first)["speed"] as? Int == 42)
        #expect(fixture.saved(for: fixture.second).isEmpty)
    }

    @Test func displayUpdatesReachOnlyThatDisplayAndPersistItsBundle() throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        fixture.install()

        fixture.manager.updateProperty("speed", value: 17, for: 202)
        fixture.manager.updateProperty("speed", value: 29, for: 303)

        #expect(fixture.runtimes[101]?.updates.isEmpty == true)
        #expect(fixture.runtimes[202]?.updates == [.init(key: "speed", value: 17)])
        #expect(fixture.runtimes[303]?.updates == [.init(key: "speed", value: 29)])
        #expect(fixture.saved(for: fixture.first)["speed"] as? Int == 17)
        #expect(fixture.saved(for: fixture.second)["speed"] as? Int == 29)
    }

    @Test func failedDisplayReceivesNeitherRouteWhileHealthyPeerStillUpdates() throws {
        let fixture = try RoutingFixture(failingDisplay: 202)
        defer { fixture.cleanup() }
        fixture.install()
        #expect(fixture.manager.currentBundle(for: 202)?.id == fixture.first.id)
        #expect(fixture.runtimes[202]?.started == false)

        fixture.manager.updateProperty("speed", value: 11, for: 202)
        #expect(fixture.saved(for: fixture.first).isEmpty)
        fixture.manager.updateProperty("speed", value: 31, forBundleID: fixture.first.id)

        #expect(fixture.runtimes[101]?.updates == [.init(key: "speed", value: 31)])
        #expect(fixture.runtimes[202]?.updates.isEmpty == true)
        #expect(fixture.runtimes[303]?.updates.isEmpty == true)
        #expect(fixture.saved(for: fixture.first)["speed"] as? Int == 31)
        #expect(fixture.saved(for: fixture.second).isEmpty)
    }

    @Test func globalSafeModeIgnoresDisplayUpdatesButSavesBundleOverrides() throws {
        let fixture = try RoutingFixture()
        defer { fixture.cleanup() }
        fixture.install()
        fixture.manager.setSafeMode(true)

        fixture.manager.updateProperty("speed", value: 7, for: 101)
        #expect(fixture.saved(for: fixture.first).isEmpty)
        fixture.manager.updateProperty("speed", value: 23, forBundleID: fixture.second.id)

        #expect(fixture.manager.isSafeMode)
        #expect(fixture.runtimes.values.allSatisfy { $0.stopped && $0.updates.isEmpty })
        #expect(fixture.saved(for: fixture.first).isEmpty)
        #expect(fixture.saved(for: fixture.second)["speed"] as? Int == 23)
    }
}

private final class RoutingDisplays: WallpaperDisplaySource {
    let displayIDs: [CGDirectDisplayID] = [101, 202, 303]
    func updateDisplayList() {}
    func hardwareInfo() -> [DisplayHardwareInfo] {
        displayIDs.map {
            DisplayHardwareInfo(displayID: $0, uuid: "routing-\($0)", vendor: 1,
                                model: 2, serial: $0,
                                frame: CGRect(x: Int($0), y: 0, width: 100, height: 100))
        }
    }
    func screen(for displayID: CGDirectDisplayID) -> NSScreen? { nil }
    func isPrimaryDisplay(_ displayID: CGDirectDisplayID) -> Bool { displayID == 101 }
}

private final class RoutingHost: WallpaperHosting {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    var isVisible = false
    var occlusionState: NSWindow.OcclusionState { [.visible] }
    func setFrame(_ frame: NSRect, display: Bool) {}
    func orderBack(_ sender: Any?) { isVisible = true }
    func orderOut(_ sender: Any?) { isVisible = false }
    func close() {}
    func setContentView(_ view: NSView) {}
    func reassertDesktopLevel() {}
}

private final class RoutingRuntime: WallpaperRuntime {
    struct Update: Equatable {
        let key: String
        let value: Int
    }
    enum Failure: Error { case start }
    let displayID: CGDirectDisplayID
    let contentView = NSView()
    var isPaused = false
    var stopped = false
    var started = false
    var updates: [Update] = []
    let failsToStart: Bool

    init(displayID: CGDirectDisplayID, failsToStart: Bool) {
        self.displayID = displayID
        self.failsToStart = failsToStart
    }
    func start() throws {
        if failsToStart { throw Failure.start }
        started = true
    }
    func pause() { isPaused = true }
    func resume() { isPaused = false }
    func stop() { stopped = true }
    func reload() throws {}
    func updateProperty(_ key: String, value: Any) {
        updates.append(Update(key: key, value: value as? Int ?? -1))
    }
}

@MainActor
private final class RoutingFixture {
    let suite = "PropertyRoutingTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let directory: URL
    let first: WallpaperBundle
    let second: WallpaperBundle
    let manager: WallpaperManager
    let runtimes: [CGDirectDisplayID: RoutingRuntime]

    init(failingDisplay: CGDirectDisplayID? = nil) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstURL = directory.appendingPathComponent(UUID().uuidString)
        let secondURL = directory.appendingPathComponent(UUID().uuidString)
        for url in [firstURL, secondURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("<html></html>".utf8).write(to: url.appendingPathComponent("index.html"))
        }
        first = try #require(WallpaperBundle(from: firstURL))
        second = try #require(WallpaperBundle(from: secondURL))
        let displays = RoutingDisplays()
        let recordings = Dictionary(uniqueKeysWithValues: displays.displayIDs.map {
            ($0, RoutingRuntime(displayID: $0, failsToStart: $0 == failingDisplay))
        })
        runtimes = recordings
        manager = WallpaperManager(displayManager: displays,
                                   wallpaperStore: WallpaperStore(userDefaults: defaults),
                                   propertyStore: PropertyStore(userDefaults: defaults),
                                   runtimeFactory: { _, id in try #require(recordings[id]) },
                                   hostFactory: { _ in RoutingHost() })
    }

    func install() {
        manager.start()
        manager.setWallpaper(first, for: 101)
        manager.setWallpaper(first, for: 202)
        manager.setWallpaper(second, for: 303)
        #expect(runtimes[101]?.started == true)
        #expect(runtimes[303]?.started == true)
        #expect(manager.currentBundle(for: 101)?.id == first.id)
        #expect(manager.currentBundle(for: 303)?.id == second.id)
    }

    func saved(for bundle: WallpaperBundle) -> [String: Any] {
        // A fresh store verifies persistence rather than the manager's cache.
        PropertyStore(userDefaults: defaults).load(for: bundle.id)
    }

    func cleanup() {
        manager.stopAll()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
