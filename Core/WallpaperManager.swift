import AppKit
import Foundation

class WallpaperManager {

    private var displayManager: DisplayManager!
    private var wallpaperHosts: [CGDirectDisplayID: WallpaperHostWindow] = [:]
    private var runtimes: [CGDirectDisplayID: WallpaperRuntime] = [:]
    private var wallpaperStore: WallpaperStore!
    private var propertyStore: PropertyStore!
    private var currentWallpaper: WallpaperBundle?
    private var isRunning = false

    init() {
        displayManager = DisplayManager()
        wallpaperStore = WallpaperStore()
        propertyStore = PropertyStore()

        setupDisplayObserver()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        displayManager.updateDisplayList()

        for displayID in displayManager.displayIDs {
            createWallpaperHost(for: displayID)
        }
    }

    func stopAll() {
        isRunning = false

        for (_, runtime) in runtimes {
            runtime.stop()
        }
        runtimes.removeAll()

        for (_, window) in wallpaperHosts {
            window.close()
        }
        wallpaperHosts.removeAll()
    }

    func reloadWallpaper(for displayID: CGDirectDisplayID) {
        guard let runtime = runtimes[displayID] else { return }

        do {
            try runtime.reload()
        } catch {
            print("AetherDesk: Failed to reload wallpaper for display \(displayID): \(error)")
        }
    }

    func setWallpaper(_ bundle: WallpaperBundle, for displayID: CGDirectDisplayID) {
        guard let hostWindow = wallpaperHosts[displayID] else { return }

        let runtime: WallpaperRuntime

        switch bundle.type {
        case .web:
            runtime = WebWallpaperRuntime(bundle: bundle, displayID: displayID)
        case .video:
            runtime = VideoWallpaperRuntime(bundle: bundle, displayID: displayID)
        case .image:
            runtime = ImageWallpaperRuntime(bundle: bundle, displayID: displayID)
        case .unknown:
            runtime = WebWallpaperRuntime(bundle: bundle, displayID: displayID)
        }

        if let existingRuntime = runtimes[displayID] {
            existingRuntime.stop()
        }

        runtimes[displayID] = runtime

        do {
            try runtime.start()
            hostWindow.setContentView(runtime.contentView)
        } catch {
            print("AetherDesk: Failed to start wallpaper: \(error)")
        }
    }

    func pauseAll() {
        for (_, runtime) in runtimes {
            runtime.pause()
        }
    }

    func resumeAll() {
        for (_, runtime) in runtimes {
            runtime.resume()
        }
    }

    func updateProperty(_ key: String, value: Any, for displayID: CGDirectDisplayID) {
        guard let runtime = runtimes[displayID] else { return }
        runtime.updateProperty(key, value: value)
    }

    private func createWallpaperHost(for displayID: CGDirectDisplayID) {
        guard let screen = displayManager.screen(for: displayID) else { return }

        let window = WallpaperHostWindow(screen: screen)
        window.setFrame(screen.frame, display: true)
        window.orderFront(nil)
        wallpaperHosts[displayID] = window
    }

    private func setupDisplayObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayConfigurationDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func displayConfigurationDidChange(_ notification: Notification) {
        displayManager.updateDisplayList()

        let currentDisplayIDs = Set(displayManager.displayIDs)
        let existingDisplayIDs = Set(wallpaperHosts.keys)

        let addedDisplayIDs = currentDisplayIDs.subtracting(existingDisplayIDs)
        let removedDisplayIDs = existingDisplayIDs.subtracting(currentDisplayIDs)

        for displayID in removedDisplayIDs {
            wallpaperHosts[displayID]?.close()
            wallpaperHosts.removeValue(forKey: displayID)
            runtimes[displayID]?.stop()
            runtimes.removeValue(forKey: displayID)
        }

        for displayID in addedDisplayIDs {
            createWallpaperHost(for: displayID)
        }
    }
}
