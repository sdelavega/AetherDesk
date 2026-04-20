import AppKit
import Foundation

/// Top-level app delegate. Runs as an accessory app (menu-bar only, no Dock
/// presence — see Info.plist LSUIElement).
final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var wallpaperManager: WallpaperManager?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let manager = WallpaperManager()
        self.wallpaperManager = manager
        self.menuBarController = MenuBarController(wallpaperManager: manager)

        manager.start()

        // Auto-select the first bundled wallpaper on all displays on first
        // launch so the user sees something without having to import first.
        if let first = WallpaperImporter().listBundledWallpapers().first {
            manager.setWallpaperOnAllDisplays(first)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wallpaperManager?.stopAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
