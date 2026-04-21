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

        // Compile (or load from cache) the content blocker rule list before
        // starting any wallpaper WebViews. On subsequent launches this is a
        // cache hit and resolves in milliseconds; first launch compiles from
        // the embedded JSON, which takes well under a second for our small list.
        ContentRuleListManager.shared.prepare {
            // Restore per-display wallpaper from persisted state, falling back
            // to the first bundled sample for any display without a prior
            // assignment (so first launch is never blank).
            let available = WallpaperImporter.shared.listWallpapers()
            let fallback = WallpaperImporter.shared.listBundledWallpapers().first
            manager.startAndRestore(availableBundles: available, fallback: fallback)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wallpaperManager?.stopAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
