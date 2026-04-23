import AppKit
import os.log
import Foundation
import IOKit.ps

/// Central orchestrator for wallpaper hosts and runtimes across all displays.
///
/// Responsibilities:
///   - own one WallpaperHostWindow per display, rebuilt as displays come and go
///   - own at most one WallpaperRuntime per display
///   - pause runtimes on display sleep / lock / low-power mode
///   - fall back to a safe mode (static solid color) when a runtime throws
///   - broadcast "current wallpaper changed" so the UI can refresh
final class WallpaperManager {

    // MARK: State

    private let displayManager = DisplayManager()
    private let wallpaperStore = WallpaperStore()
    private let propertyStore  = PropertyStore()
    private var performanceSettings = AppSettingsStore.shared.loadPerformanceSettings()

    private var hosts: [CGDirectDisplayID: WallpaperHostWindow] = [:]
    private var runtimes: [CGDirectDisplayID: WallpaperRuntime] = [:]
    private var currentBundles: [CGDirectDisplayID: WallpaperBundle] = [:]

    private(set) var isRunning = false
    private(set) var isSafeMode = false
    private var fallbackBundle: WallpaperBundle?
    private var occludedDisplays: Set<CGDirectDisplayID> = []
    /// Snapshot of the last known display set. Used to detect redundant
    /// displayConfigurationDidChange notifications (e.g. wake + notification).
    private var lastKnownDisplayIDs: Set<CGDirectDisplayID> = []

    // MARK: Lifecycle

    init() {
        // DisplayManager.init() already calls updateDisplayList(); no need to
        // duplicate it here. start() will call it again if needed.
        registerObservers()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true
        displayManager.updateDisplayList()
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

        let saved = wallpaperStore.loadAssignments(for: displayManager.displayIDs)

        for displayID in displayManager.displayIDs {
            if let savedID = saved[displayID], let bundle = byID[savedID] {
                setWallpaper(bundle, for: displayID)
            } else if let fallback = fallback {
                setWallpaper(fallback, for: displayID)
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
    }

    /// Install a wallpaper on a specific display. Starts the appropriate
    /// runtime; on failure, installs safe-mode fallback content for that
    /// display and posts an error notification.
    func setWallpaper(_ bundle: WallpaperBundle, for displayID: CGDirectDisplayID) {
        ensureHost(for: displayID)
        guard let host = hosts[displayID] else { return }

        // Tear down any previous runtime on this display.
        runtimes[displayID]?.stop()
        runtimes.removeValue(forKey: displayID)

        let runtime = makeRuntime(for: bundle, displayID: displayID)

        do {
            let overrides = propertyStore.load(for: bundle.id)
            if let webRuntime = runtime as? WebWallpaperRuntime {
                webRuntime.setInitialOverrides(overrides)
            }
            try runtime.start()
            runtimes[displayID] = runtime
            currentBundles[displayID] = bundle
            host.setContentView(runtime.contentView)
            if !host.isVisible { host.orderBack(nil) }

            for (k, v) in overrides {
                runtime.updateProperty(k, value: v)
            }

            // Persist (displayID -> bundleID) so next launch restores this.
            wallpaperStore.setAssignment(bundleID: bundle.id, for: displayID)

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
        if let bundle = currentBundles[displayID] {
            var overrides = propertyStore.load(for: bundle.id)
            overrides[key] = value
            propertyStore.save(overrides, for: bundle.id)
        }
    }

    func updateProperty(_ key: String, value: Any, forBundleID bundleID: UUID) {
        for (displayID, bundle) in currentBundles where bundle.id == bundleID {
            runtimes[displayID]?.updateProperty(key, value: value)
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
            for (id, bundle) in currentBundles {
                setWallpaper(bundle, for: id)
            }
        }
    }

    func currentBundle(for displayID: CGDirectDisplayID) -> WallpaperBundle? {
        currentBundles[displayID]
    }

    // MARK: Runtime factory

    private func makeRuntime(for bundle: WallpaperBundle,
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
        guard let screen = displayManager.screen(for: displayID) else { return }
        let host = WallpaperHostWindow(screen: screen)
        host.setFrame(screen.frame, display: true)
        host.orderBack(nil)
        hosts[displayID] = host
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowOcclusionStateDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: host)
    }

    private func installSafeModeContent(for displayID: CGDirectDisplayID) {
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
        displayManager.updateDisplayList()

        let current = Set(displayManager.displayIDs)
        let existing = Set(hosts.keys)
        let displaySetChanged = current != lastKnownDisplayIDs
        lastKnownDisplayIDs = current

        if displaySetChanged {
            let added   = current.subtracting(existing)
            let removed = existing.subtracting(current)

            for id in removed {
                runtimes[id]?.stop()
                runtimes.removeValue(forKey: id)
                occludedDisplays.remove(id)
                // Keep currentBundles[id] — the display may return (e.g., lid
                // open) and we need the bundle reference to restore it.
                // The persisted wallpaperStore assignment is also preserved.
                if let host = hosts[id] {
                    NotificationCenter.default.removeObserver(
                        self,
                        name: NSWindow.didChangeOcclusionStateNotification,
                        object: host)
                    host.orderOut(nil)
                    host.close()
                }
                hosts.removeValue(forKey: id)
            }

            for id in added {
                ensureHost(for: id)
                if runtimes[id] == nil {
                    if let bundle = currentBundles[id] {
                        // Display reconnected this session (lid open, cable replug).
                        setWallpaper(bundle, for: id)
                    } else {
                        // Genuinely new display — try persistence, then fallback.
                        // Directory scans can hitch the main thread; do the lookup
                        // on a background queue and apply on main.
                        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                            guard let self = self else { return }
                            let available = WallpaperImporter.shared.listWallpapers()
                            let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
                            let saved = self.wallpaperStore.loadAssignments(for: [id])
                            DispatchQueue.main.async {
                                if let savedID = saved[id], let bundle = byID[savedID] {
                                    self.setWallpaper(bundle, for: id)
                                } else if let fallback = self.fallbackBundle {
                                    self.setWallpaper(fallback, for: id)
                                }
                            }
                        }
                    }
                }
            }
        }

        // Re-align frames for any kept displays (resolution / position changes).
        for (id, host) in hosts {
            if let screen = displayManager.screen(for: id) {
                host.setFrame(screen.frame, display: true)
            }
        }

        NotificationCenter.default.post(name: Constants.Notifications.displayConfigurationDidChange,
                                        object: nil)
    }

    @objc private func sessionDidResignActive() { pauseAll() }
    @objc private func sessionDidBecomeActive() { applyPowerPerformancePolicy() }
    @objc private func screenDidSleep() { pauseAll() }

    @objc private func screenDidWake() {
        guard isRunning else { return }

        // The display list may have changed during sleep (lid open, external
        // monitor reconnected). Refresh and ensure hosts exist.
        displayManager.updateDisplayList()
        for displayID in displayManager.displayIDs {
            ensureHost(for: displayID)
        }

        // macOS can reset window levels after wake — reassert desktop level.
        for (_, host) in hosts {
            host.reassertDesktopLevel()
        }

        // Restore wallpapers on any display that lost its runtime during sleep
        // (e.g., display was "removed" on lid close, tearing down the runtime,
        // then "re-added" on lid open).
        for displayID in displayManager.displayIDs {
            if runtimes[displayID] == nil, let bundle = currentBundles[displayID] {
                setWallpaper(bundle, for: displayID)
            }
        }

        applyPowerPerformancePolicy()
    }

    @objc private func thermalStateChanged() {
        guard performanceSettings.respectLowPowerMode else { return }
        if ProcessInfo.processInfo.thermalState == .critical { pauseAll() }
        else { applyPowerPerformancePolicy() }
    }

    @objc private func powerStateChanged() {
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

        for (displayID, bundle) in currentBundles where bundle.id == bundleID {
            currentBundles.removeValue(forKey: displayID)
            if let replacement = fallbackBundle {
                setWallpaper(replacement, for: displayID)
            } else {
                installSafeModeContent(for: displayID)
            }
        }
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
           isOnBatteryPower {
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

    private var isOnBatteryPower: Bool {
        IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() == nil
    }
}
