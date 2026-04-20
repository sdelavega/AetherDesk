import AppKit
import Foundation

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

    private var hosts: [CGDirectDisplayID: WallpaperHostWindow] = [:]
    private var runtimes: [CGDirectDisplayID: WallpaperRuntime] = [:]
    private var currentBundles: [CGDirectDisplayID: WallpaperBundle] = [:]

    private(set) var isRunning = false
    private(set) var isSafeMode = false

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

        let byID = Dictionary(uniqueKeysWithValues: availableBundles.map { ($0.id, $0) })
        wallpaperStore.pruneMissing(knownBundleIDs: Set(byID.keys))

        let saved = wallpaperStore.loadAssignments()

        for displayID in displayManager.displayIDs {
            if let savedID = saved[displayID], let bundle = byID[savedID] {
                setWallpaper(bundle, for: displayID)
            } else if let fallback = fallback {
                setWallpaper(fallback, for: displayID)
            }
        }
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
            try runtime.start()
            runtimes[displayID] = runtime
            currentBundles[displayID] = bundle
            host.setContentView(runtime.contentView)
            if !host.isVisible { host.orderBack(nil) }

            // Replay persisted property overrides if any.
            let overrides = propertyStore.load(for: bundle.id)
            for (k, v) in overrides { runtime.updateProperty(k, value: v) }

            // Persist (displayID -> bundleID) so next launch restores this.
            wallpaperStore.setAssignment(bundleID: bundle.id, for: displayID)

            NotificationCenter.default.post(name: Constants.Notifications.wallpaperDidChange,
                                            object: nil,
                                            userInfo: ["displayID": displayID,
                                                       "bundleID": bundle.id.uuidString])
        } catch {
            NSLog("ÆtherDesk: runtime start failed for display %u: %@",
                  displayID, String(describing: error))
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
            NSLog("ÆtherDesk: reload failed for display %u: %@",
                  displayID, String(describing: error))
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
        for (_, runtime) in runtimes { runtime.resume() }
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
    }

    @objc private func displayConfigurationDidChange(_ notification: Notification) {
        displayManager.updateDisplayList()

        let current = Set(displayManager.displayIDs)
        let existing = Set(hosts.keys)

        let added   = current.subtracting(existing)
        let removed = existing.subtracting(current)

        for id in removed {
            runtimes[id]?.stop()
            runtimes.removeValue(forKey: id)
            currentBundles.removeValue(forKey: id)
            hosts[id]?.orderOut(nil)
            hosts[id]?.close()
            hosts.removeValue(forKey: id)
            // Don't wipe the persisted assignment — the display may come back
            // later. pruneMissing() at next launch handles the truly-stale case.
        }

        for id in added { ensureHost(for: id) }

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
    @objc private func sessionDidBecomeActive() { resumeAll() }
    @objc private func screenDidSleep()         { pauseAll() }
    @objc private func screenDidWake()          { resumeAll() }

    @objc private func thermalStateChanged() {
        if ProcessInfo.processInfo.thermalState == .critical { pauseAll() }
        else { resumeAll() }
    }

    @objc private func powerStateChanged() {
        if #available(macOS 12.0, *) {
            if ProcessInfo.processInfo.isLowPowerModeEnabled { pauseAll() }
            else { resumeAll() }
        }
        NotificationCenter.default.post(name: Constants.Notifications.lowPowerModeDidChange,
                                        object: nil)
    }

    @objc private func runtimeDidFail(_ note: Notification) {
        guard let displayID = note.userInfo?["displayID"] as? CGDirectDisplayID else { return }
        let reason = (note.userInfo?["reason"] as? String) ?? "unknown"
        NSLog("ÆtherDesk: runtime on display %u reported failure (%@); demoting to safe content",
              displayID, reason)
        DispatchQueue.main.async { [weak self] in
            self?.installSafeModeContent(for: displayID)
        }
    }
}
