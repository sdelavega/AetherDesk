import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?
    private var wallpaperManager: WallpaperManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        wallpaperManager = WallpaperManager()
        menuBarController = MenuBarController(wallpaperManager: wallpaperManager!)

        wallpaperManager?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        wallpaperManager?.stopAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
