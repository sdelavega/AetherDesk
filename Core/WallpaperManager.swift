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

import AppKit
import os.log
import Foundation
import IOKit.ps

protocol WallpaperDisplaySource: AnyObject {
    var displayIDs: [CGDirectDisplayID] { get }
    func updateDisplayList()
    func hardwareInfo() -> [DisplayHardwareInfo]
    func screen(for displayID: CGDirectDisplayID) -> NSScreen?
    func isPrimaryDisplay(_ displayID: CGDirectDisplayID) -> Bool
}

extension DisplayManager: WallpaperDisplaySource {}

protocol WallpaperHosting: AnyObject {
    var frame: NSRect { get }
    var isVisible: Bool { get }
    var occlusionState: NSWindow.OcclusionState { get }
    func setFrame(_ frame: NSRect, display: Bool)
    func orderBack(_ sender: Any?)
    func orderOut(_ sender: Any?)
    func close()
    func setContentView(_ view: NSView)
    func reassertDesktopLevel()
}

extension WallpaperHostWindow: WallpaperHosting {}

/// Central orchestrator for wallpaper hosts and runtimes across all displays.
///
/// Responsibilities:
///   - own one WallpaperHostWindow per display, rebuilt as displays come and go
///   - own at most one WallpaperRuntime per display
///   - pause runtimes on display sleep / lock / low-power mode
///   - fall back to a safe mode (static solid color) when a runtime throws
///   - broadcast "current wallpaper changed" so the UI can refresh
final class WallpaperManager {
    typealias RuntimeFactory = (WallpaperBundle, CGDirectDisplayID) throws -> WallpaperRuntime

    // MARK: State

    private let displayManager: WallpaperDisplaySource
    private let wallpaperStore: WallpaperStore
    private let propertyStore: PropertyStore
    private let runtimeFactory: RuntimeFactory
    private let hostFactory: (CGDirectDisplayID) -> WallpaperHosting?
    private var performanceSettings = AppSettingsStore.shared.loadPerformanceSettings()

    private var hosts: [CGDirectDisplayID: WallpaperHosting] = [:]
    private var runtimes: [CGDirectDisplayID: WallpaperRuntime] = [:]
    private var currentBundles: [DisplayIdentity: WallpaperBundle] = [:]
    private var displaySnapshots: [DisplaySnapshot] = []
    private var restoreRequests: [CGDirectDisplayID: UUID] = [:]
    private var safeModeRetryPolicy = SafeModeRetryPolicy()
    private var demotedDisplays: Set<DisplayIdentity> = []
    private var wakeReconcilePending = false
    private let displayChangeCoalescer = DisplayChangeCoalescer { delay, action in
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    private(set) var isRunning = false
    private(set) var isSafeMode = false
    private var fallbackBundle: WallpaperBundle?
    private var occludedDisplays: Set<CGDirectDisplayID> = []
    private var powerSource: CFRunLoopSource?
    // Session bundles survive disconnects; snapshots describe only active displays.

    // MARK: Lifecycle

    init(displayManager: WallpaperDisplaySource = DisplayManager(),
         wallpaperStore: WallpaperStore = WallpaperStore(),
         propertyStore: PropertyStore = PropertyStore(),
         runtimeFactory: @escaping RuntimeFactory = WallpaperManager.makeRuntime,
         hostFactory: ((CGDirectDisplayID) -> WallpaperHosting?)? = nil) {
        self.displayManager = displayManager
        self.wallpaperStore = wallpaperStore
        self.propertyStore = propertyStore
        self.runtimeFactory = runtimeFactory
        self.hostFactory = hostFactory ?? { displayID in
            guard let screen = displayManager.screen(for: displayID) else { return nil }
            return WallpaperHostWindow(screen: screen)
        }
        // DisplayManager.init() already calls updateDisplayList(); no need to
        // duplicate it here. start() will call it again if needed.
        displayChangeCoalescer.onFire = { [weak self] in
            self?.reconcileDisplays()
        }
        registerObservers()
    }

    deinit {
        if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true
        displayManager.updateDisplayList()
        displaySnapshots = snapshots(for: displayManager.hardwareInfo())
        updateGeometryCache()
        for displayID in displayManager.displayIDs {
            ensureHost(for: displayID)
        }
    }

    /// Boot-time convenience: start hosts, then restore the persisted
    /// (display -> bundle) mapping from `WallpaperStore`. Any display with
    /// no saved assignment (or whose saved bundle is no longer resolvable)
    /// gets `fallback` instead. If `fallback` is nil, such displays stay on
    /// the safe black view.
    func startAndRestore(availableBundles: [WallpaperBundle],
                         fallback: WallpaperBundle?) {
        start()
        self.fallbackBundle = fallback

        let byID = Dictionary(uniqueKeysWithValues: availableBundles.map { ($0.id, $0) })
        wallpaperStore.pruneMissing(knownBundleIDs: Set(byID.keys))

        let saved = wallpaperStore.loadAssignments(for: displayManager.hardwareInfo())

        for displayID in displayManager.displayIDs {
            if let savedID = saved[displayID], let bundle = byID[savedID] {
                installWallpaper(bundle, for: displayID)
            } else if let fallback = fallback {
                installWallpaper(fallback, for: displayID)
            }
        }
        applyPowerPerformancePolicy()
    }

    func stopAll() {
        isRunning = false
        for (_, runtime) in runtimes { runtime.stop() }
        runtimes.removeAll()
        for (_, host) in hosts {
            host.orderOut(nil)
            host.close()
        }
        hosts.removeAll()
        currentBundles.removeAll()
        demotedDisplays.removeAll()
        safeModeRetryPolicy = SafeModeRetryPolicy()
        wakeReconcilePending = false
        displaySnapshots.removeAll()
        restoreRequests.removeAll()
        DisplayGeometryCache.shared.invalidate()
    }

    /// Install a wallpaper on a specific display. Starts the appropriate
    /// runtime; on failure, installs safe-mode fallback content for that
    /// display and posts an error notification.
    func setWallpaper(_ bundle: WallpaperBundle, for displayID: CGDirectDisplayID) {
        if let identity = identity(for: displayID) {
            safeModeRetryPolicy.reset(identity)
        }
        installWallpaper(bundle, for: displayID)
    }

    private func installWallpaper(_ bundle: WallpaperBundle, for displayID: CGDirectDisplayID) {
        guard let identity = identity(for: displayID) else {
            Logger.app.warning("ÆtherDesk: cannot set wallpaper for display \(displayID): missing display identity")
            return
        }
        restoreRequests.removeValue(forKey: displayID)
        ensureHost(for: displayID)
        guard let host = hosts[displayID] else { return }

        // Tear down any previous runtime on this display.
        runtimes[displayID]?.stop()
        runtimes.removeValue(forKey: displayID)

        // Retain the requested bundle even if starting it immediately fails.
        currentBundles[identity] = bundle
        do {
            let runtime = try runtimeFactory(bundle, displayID)
            let overrides = propertyStore.load(for: bundle.id)
            if let webRuntime = runtime as? WebWallpaperRuntime {
                webRuntime.setInitialOverrides(overrides)
            }
            try runtime.start()
            runtimes[displayID] = runtime
            demotedDisplays.remove(identity)
            host.setContentView(runtime.contentView)
            if !host.isVisible { host.orderBack(nil) }

            for (k, v) in overrides {
                runtime.updateProperty(k, value: v)
            }

            // Persist (displayID -> bundleID) so next launch restores this.
            let displays = displayManager.hardwareInfo()
            if let info = displays.first(where: { $0.displayID == displayID }) {
                wallpaperStore.setAssignment(bundleID: bundle.id, for: info, among: displays)
            }

            NotificationCenter.default.post(name: Constants.Notifications.wallpaperDidChange,
                                            object: nil,
                                            userInfo: ["displayID": displayID,
                                                       "bundleID": bundle.id.uuidString])
            applyPowerPerformancePolicy()
        } catch {
            Logger.app.error("ÆtherDesk: runtime start failed for display \(displayID): \(String(describing: error))")
            installSafeModeContent(for: displayID)
        }
    }

    func setWallpaperOnAllDisplays(_ bundle: WallpaperBundle) {
        for displayID in displayManager.displayIDs {
            setWallpaper(bundle, for: displayID)
        }
    }

    func reloadWallpaper(for displayID: CGDirectDisplayID) {
        guard let runtime = runtimes[displayID] else { return }
        do { try runtime.reload() }
        catch {
            Logger.app.error("ÆtherDesk: reload failed for display \(displayID): \(String(describing: error))")
            installSafeModeContent(for: displayID)
        }
    }

    func reloadAll() {
        for id in runtimes.keys { reloadWallpaper(for: id) }
    }

    func pauseAll() {
        for (_, runtime) in runtimes { runtime.pause() }
    }

    func resumeAll() {
        guard !isSafeMode else { return }
        for (id, runtime) in runtimes {
            if performanceSettings.pauseWhenNotVisible && occludedDisplays.contains(id) { continue }
            runtime.resume()
        }
    }

    func updateProperty(_ key: String, value: Any, for displayID: CGDirectDisplayID) {
        guard let runtime = runtimes[displayID] else { return }
        runtime.updateProperty(key, value: value)
        if let bundle = currentBundle(for: displayID) {
            var overrides = propertyStore.load(for: bundle.id)
            overrides[key] = value
            propertyStore.save(overrides, for: bundle.id)
        }
    }

    func updateProperty(_ key: String, value: Any, forBundleID bundleID: UUID) {
        for display in displaySnapshots where currentBundles[display.identity]?.id == bundleID {
            runtimes[display.info.displayID]?.updateProperty(key, value: value)
        }

        var overrides = propertyStore.load(for: bundleID)
        overrides[key] = value
        propertyStore.save(overrides, for: bundleID)
    }

    /// Flip safe mode on/off. In safe mode all runtimes are paused and the
    /// hosts are filled with a static, inert fallback so a misbehaving
    /// wallpaper can't continue to churn CPU.
    func setSafeMode(_ enabled: Bool) {
        guard enabled != isSafeMode else { return }
        isSafeMode = enabled
        if enabled {
            for (id, _) in hosts { installSafeModeContent(for: id) }
        } else {
            // Best-effort: re-run last known good bundles.
            for display in displaySnapshots {
                if let bundle = currentBundles[display.identity] {
                    installWallpaper(bundle, for: display.info.displayID)
                }
            }
        }
    }

    func currentBundle(for displayID: CGDirectDisplayID) -> WallpaperBundle? {
        guard let identity = identity(for: displayID) else { return nil }
        return currentBundles[identity]
    }

    private func identity(for displayID: CGDirectDisplayID) -> DisplayIdentity? {
        displaySnapshots.first { $0.info.displayID == displayID }?.identity
    }

    private func snapshots(for displays: [DisplayHardwareInfo]) -> [DisplaySnapshot] {
        displays.map { DisplaySnapshot(info: $0, identity: DisplayIdentity.primary(for: $0, among: displays)) }
    }

    private func updateGeometryCache() {
        var entries: [CGDirectDisplayID: (CGRect, CGFloat, Bool)] = [:]
        for displayID in displayManager.displayIDs {
            guard let screen = displayManager.screen(for: displayID) else { continue }
            entries[displayID] = (screen.frame, screen.backingScaleFactor,
                                  displayManager.isPrimaryDisplay(displayID))
        }
        DisplayGeometryCache.shared.update(entries)
    }

    // MARK: Runtime factory

    static func makeRuntime(for bundle: WallpaperBundle,
                            displayID: CGDirectDisplayID) -> WallpaperRuntime {
        switch bundle.type {
        case .web:
            return WebWallpaperRuntime(bundle: bundle, displayID: displayID)
        case .video:
            return VideoWallpaperRuntime(bundle: bundle, displayID: displayID)
        case .image:
            return ImageWallpaperRuntime(bundle: bundle, displayID: displayID)
        case .unknown:
            // v1 policy: unknown = rejected at import-time, but if we ever get
            // here, fall through to a web attempt (it's the most flexible).
            return WebWallpaperRuntime(bundle: bundle, displayID: displayID)
        }
    }

    // MARK: Host / display management

    private func ensureHost(for displayID: CGDirectDisplayID) {
        if hosts[displayID] != nil { return }
        guard let host = hostFactory(displayID) else { return }
        host.setFrame(host.frame, display: true)
        host.orderBack(nil)
        hosts[displayID] = host
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowOcclusionStateDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: host)
    }

    private func installSafeModeContent(for displayID: CGDirectDisplayID) {
        if let identity = identity(for: displayID) {
            demotedDisplays.insert(identity)
            safeModeRetryPolicy.recordDemotion(identity)
        }
        guard let host = hosts[displayID] else { return }
        runtimes[displayID]?.stop()
        runtimes.removeValue(forKey: displayID)

        let fallback = NSView(frame: host.frame)
        fallback.wantsLayer = true
        fallback.layer?.backgroundColor = NSColor.black.cgColor
        fallback.autoresizingMask = [.width, .height]
        host.setContentView(fallback)
    }

    // MARK: Observers

    private func registerObservers() {
        powerSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<WallpaperManager>.fromOpaque(context).takeUnretainedValue().powerStateChanged()
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSource { CFRunLoopAddSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        let nc = NotificationCenter.default

        nc.addObserver(self,
                       selector: #selector(displayConfigurationDidChange),
                       name: NSApplication.didChangeScreenParametersNotification,
                       object: nil)

        // Pause when user session is inactive (screen locked / fast user switch).
        nc.addObserver(self,
                       selector: #selector(sessionDidResignActive),
                       name: NSWorkspace.sessionDidResignActiveNotification,
                       object: nil)
        nc.addObserver(self,
                       selector: #selector(sessionDidBecomeActive),
                       name: NSWorkspace.sessionDidBecomeActiveNotification,
                       object: nil)

        // Respect Low Power Mode (macOS 12+).
        if #available(macOS 12.0, *) {
            nc.addObserver(self,
                           selector: #selector(thermalStateChanged),
                           name: ProcessInfo.thermalStateDidChangeNotification,
                           object: nil)
            nc.addObserver(self,
                           selector: #selector(powerStateChanged),
                           name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
                           object: nil)
        }

        // Pause when memory pressure becomes critical.
        nc.addObserver(self,
                       selector: #selector(memoryPressureStateChanged),
                       name: NSNotification.Name("NSProcessInfoMemoryPressureNotification"),
                       object: nil)

        // Pause on display sleep / unpause on wake.
        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(self, selector: #selector(screenDidSleep),
                         name: NSWorkspace.screensDidSleepNotification, object: nil)
        wsnc.addObserver(self, selector: #selector(screenDidWake),
                         name: NSWorkspace.screensDidWakeNotification, object: nil)

        // Runtime self-reports: watchdog trip, web content termination, AV
        // playback failure. Demote the affected display to safe content.
        nc.addObserver(self,
                       selector: #selector(runtimeDidFail(_:)),
                       name: Constants.Notifications.runtimeDidFail,
                       object: nil)

        nc.addObserver(self,
                       selector: #selector(performanceSettingsDidChange(_:)),
                       name: AppSettingsStore.performanceSettingsDidChange,
                       object: nil)

        nc.addObserver(self,
                       selector: #selector(wallpaperDeleted(_:)),
                       name: Constants.Notifications.wallpaperDeleted,
                       object: nil)
    }

    @objc private func displayConfigurationDidChange(_ notification: Notification) {
        guard isRunning else { return }
        displayChangeCoalescer.signal()
    }

    private func reconcileDisplays() {
        guard isRunning else { return }
        displayManager.updateDisplayList()
        let displays = displayManager.hardwareInfo()
        let current = snapshots(for: displays)
        updateGeometryCache()
        let actions = DisplayReconciler.reconcile(previous: displaySnapshots, current: current,
                                                 sessionBundles: currentBundles.mapValues(\.id))
        displaySnapshots = current

        for action in actions {
            switch action {
            case .tearDownHost(let id):
                restoreRequests.removeValue(forKey: id)
                runtimes.removeValue(forKey: id)?.stop()
                occludedDisplays.remove(id)
                if let host = hosts.removeValue(forKey: id) {
                    NotificationCenter.default.removeObserver(self,
                        name: NSWindow.didChangeOcclusionStateNotification, object: host)
                    host.orderOut(nil)
                    host.close()
                }
            case .createHost(let id, _):
                ensureHost(for: id)
            case .restore(let id, let source):
                switch source {
                case .session(let bundleID):
                    if let identity = identity(for: id),
                       let bundle = currentBundles[identity], bundle.id == bundleID {
                        if demotedDisplays.contains(identity) {
                            // Reconnection must not bypass the wake retry budget.
                            installSafeModeContent(for: id)
                        } else {
                            installWallpaper(bundle, for: id)
                        }
                    } else {
                        Logger.app.warning("ÆtherDesk: session restore mismatch for display \(id), expected bundle \(bundleID)")
                    }
                case .persisted:
                    restorePersistedWallpaper(for: id, among: displays)
                case .fallback:
                    if let fallback = fallbackBundle { installWallpaper(fallback, for: id) }
                }
            case .reframeHost(let id, _):
                // Reconciler frames are Quartz coordinates; windows use AppKit.
                if let screen = displayManager.screen(for: id) {
                    hosts[id]?.setFrame(screen.frame, display: true)
                }
                runtimes[id]?.displayGeometryDidChange()
            }
        }
        if wakeReconcilePending {
            wakeReconcilePending = false
            completeWakeReconcile()
        }
        applyPowerPerformancePolicy()
        NotificationCenter.default.post(name: Constants.Notifications.displayConfigurationDidChange,
                                        object: nil)
    }

    private func restorePersistedWallpaper(for id: CGDirectDisplayID,
                                          among displays: [DisplayHardwareInfo]) {
        guard let identity = identity(for: id), hosts[id] != nil else { return }
        let request = UUID()
        restoreRequests[id] = request
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let available = WallpaperImporter.shared.listWallpapers()
            let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
            let saved = self.wallpaperStore.loadAssignments(for: displays)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, self.identity(for: id) == identity,
                      self.restoreRequests[id] == request, self.hosts[id] != nil else { return }
                self.restoreRequests.removeValue(forKey: id)
                if let savedID = saved[id], let bundle = byID[savedID] {
                    self.installWallpaper(bundle, for: id)
                } else if let fallback = self.fallbackBundle {
                    self.installWallpaper(fallback, for: id)
                }
            }
        }
    }

    @objc private func sessionDidResignActive() { pauseAll() }
    @objc private func sessionDidBecomeActive() { applyPowerPerformancePolicy() }

        @objc private func memoryPressureStateChanged() {
        // The notification itself indicates memory pressure.
        Logger.app.warning("ÆtherDesk: memory pressure notification — pausing all runtimes")
        pauseAll()
    }
    @objc private func screenDidSleep() { pauseAll() }

    @objc private func screenDidWake() {
        guard isRunning else { return }
        wakeReconcilePending = true
        displayChangeCoalescer.signal()
    }

    private func completeWakeReconcile() {
        // Hosts and identities are current only after the coalesced reconcile.
        for (_, host) in hosts {
            host.reassertDesktopLevel()
        }
        guard !isSafeMode else { return }
        for display in displaySnapshots {
            let identity = display.identity
            let displayID = display.info.displayID
            guard demotedDisplays.contains(identity), hosts[displayID] != nil,
                  let bundle = currentBundles[identity],
                  safeModeRetryPolicy.shouldRetry(identity) else { continue }
            // Automatic installation preserves the consumed retry allowance.
            installWallpaper(bundle, for: displayID)
        }
    }

    @objc private func thermalStateChanged() {
        guard performanceSettings.respectLowPowerMode else { return }
        if ProcessInfo.processInfo.thermalState == .critical { pauseAll() }
        else { applyPowerPerformancePolicy() }
    }

    @objc private func powerStateChanged() {
        for runtime in runtimes.values {
            (runtime as? WebWallpaperRuntime)?.refreshEnvironment()
        }
        applyPowerPerformancePolicy()
        NotificationCenter.default.post(name: Constants.Notifications.lowPowerModeDidChange,
                                        object: nil)
    }

    @objc private func windowOcclusionStateDidChange(_ note: Notification) {
        guard let host = note.object as? WallpaperHostWindow else { return }
        let displayID = host.targetDisplayID
        let isVisible = host.occlusionState.contains(.visible)

        if isVisible {
            occludedDisplays.remove(displayID)
            if performanceSettings.pauseWhenNotVisible {
                // Let the full policy re-evaluate — resumeAll() will skip
                // still-occluded displays and honour low-power/battery state.
                applyPowerPerformancePolicy()
            }
        } else {
            occludedDisplays.insert(displayID)
            if performanceSettings.pauseWhenNotVisible {
                runtimes[displayID]?.pause()
            }
        }
    }

    @objc private func performanceSettingsDidChange(_ note: Notification) {
        let oldSettings = performanceSettings
        if let settings = note.object as? PerformanceSettings {
            performanceSettings = settings
        } else {
            performanceSettings = AppSettingsStore.shared.loadPerformanceSettings()
        }

        // If occlusion pausing was just enabled, immediately pause any
        // displays that are already occluded.
        if performanceSettings.pauseWhenNotVisible && !oldSettings.pauseWhenNotVisible {
            for (id, host) in hosts where !host.occlusionState.contains(.visible) {
                occludedDisplays.insert(id)
                runtimes[id]?.pause()
            }
        }

        if performanceSettings.clampedFPSCap != oldSettings.clampedFPSCap ||
            performanceSettings.blockExternalNetwork != oldSettings.blockExternalNetwork {
            reloadAll()
        }
        applyPowerPerformancePolicy()
    }

    @objc private func wallpaperDeleted(_ note: Notification) {
        guard let bundleIDString = note.userInfo?["bundleID"] as? String,
              let bundleID = UUID(uuidString: bundleIDString) else { return }

        let affected = Set(currentBundles.filter { $0.value.id == bundleID }.keys)
        for identity in affected { currentBundles.removeValue(forKey: identity) }
        for display in displaySnapshots where affected.contains(display.identity) {
            let displayID = display.info.displayID
            if let replacement = fallbackBundle, replacement.id != bundleID {
                installWallpaper(replacement, for: displayID)
            } else {
                installSafeModeContent(for: displayID)
            }
        }
        if fallbackBundle?.id == bundleID { fallbackBundle = nil }
    }

    @objc private func runtimeDidFail(_ note: Notification) {
        guard let displayID = note.userInfo?["displayID"] as? CGDirectDisplayID else { return }
        let reason = (note.userInfo?["reason"] as? String) ?? "unknown"
        Logger.app.error("ÆtherDesk: runtime on display \(displayID) reported failure (\(reason)); demoting to safe content")
        DispatchQueue.main.async { [weak self] in
            self?.installSafeModeContent(for: displayID)
        }
    }

    private func applyPowerPerformancePolicy() {
        guard isRunning else { return }

        if performanceSettings.respectLowPowerMode,
           isLowPowerModeEnabled {
            pauseAll()
            return
        }

        if performanceSettings.pauseOnBatteryPower,
           Self.isOnBatteryPower {
            pauseAll()
            return
        }

        resumeAll()
    }

    private var isLowPowerModeEnabled: Bool {
        if #available(macOS 12.0, *) {
            return ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        return false
    }

    /// True only when the system is actually drawing from an internal battery.
    ///
    /// Uses the *providing* power-source type rather than the presence of an
    /// external power adapter. `IOPSCopyExternalPowerAdapterDetails()` returns
    /// nil on battery-less desktops (Mac mini, Studio, Pro, iMac), so the old
    /// `== nil` test read those machines as "on battery" — which, with
    /// `pauseOnBatteryPower` enabled, would freeze the wallpaper permanently on
    /// a desktop. `IOPSGetProvidingPowerSourceType` reports "AC Power" on those
    /// machines and only "Battery Power" on a portable actually running unplugged.
    static var isOnBatteryPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        let type = IOPSGetProvidingPowerSourceType(snapshot).takeUnretainedValue() as String
        return type == (kIOPSBatteryPowerValue as String)
    }
}
