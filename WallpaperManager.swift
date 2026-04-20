import AppKit

class WallpaperManager {

    private class HostWindow: NSWindow {
        init(screen: NSScreen) {
            super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            level = .desktop
            isOpaque = false
            backgroundColor = .clear
            ignoresMouseEvents = true
            collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            setFrame(screen.frame, display: true)
        }
    }

    private var runtimes: [CGDirectDisplayID: WallpaperRuntime] = [:]
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    func setWallpaper(_ bundle: WallpaperBundle, for displayID: CGDirectDisplayID) {
        tearDown(for: displayID)

        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }

        let runtime: WallpaperRuntime
        switch bundle.type {
        case .web:
            runtime = WebWallpaperRuntime(bundle: bundle, displayID: displayID)
        case .video:
            runtime = VideoWallpaperRuntime(bundle: bundle, displayID: displayID)
        case .image:
            // For now, treat image as video unsupported; could add image runtime later.
            return
        case .unknown:
            return
        }

        let window = HostWindow(screen: screen)
        window.contentView = runtime.contentView
        window.orderBack(nil)

        windows[displayID] = window
        runtimes[displayID] = runtime

        do {
            try runtime.start()
        } catch {
            print("AetherDesk: Failed to start runtime: \(error)")
            tearDown(for: displayID)
        }
    }

    func reloadWallpaper(for displayID: CGDirectDisplayID) {
        guard let runtime = runtimes[displayID] else { return }
        do {
            try runtime.reload()
        } catch {
            print("AetherDesk: Failed to reload runtime: \(error)")
        }
    }

    func pauseAll() {
        for (_, runtime) in runtimes { runtime.pause() }
    }

    func resumeAll() {
        for (_, runtime) in runtimes { runtime.resume() }
    }

    func tearDown(for displayID: CGDirectDisplayID) {
        if let runtime = runtimes.removeValue(forKey: displayID) {
            runtime.stop()
        }
        if let window = windows.removeValue(forKey: displayID) {
            window.orderOut(nil)
        }
    }
}
