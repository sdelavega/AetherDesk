import AppKit
import Foundation

class MenuBarController: NSObject {

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private weak var wallpaperManager: WallpaperManager?
    private let wallpaperImporter = WallpaperImporter()

    init(wallpaperManager: WallpaperManager) {
        self.wallpaperManager = wallpaperManager
        super.init()

        setupStatusItem()
        setupMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "wallpaper", accessibilityDescription: "AetherDesk")
            button.image?.isTemplate = true
        }

        statusItem.menu = nil
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.target = self
    }

    private func setupMenu() {
        menu = NSMenu()
        menu.addItem(NSMenuItem(title: "AetherDesk", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let wallpapersItem = NSMenuItem(title: "Wallpapers", action: nil, keyEquivalent: "")
        let wallpapersSubmenu = NSMenu()
        let installedWallpapers = wallpaperImporter.listWallpapers()

        if installedWallpapers.isEmpty {
            let noWallpapersItem = NSMenuItem(title: "No wallpapers installed", action: nil, keyEquivalent: "")
            noWallpapersItem.isEnabled = false
            wallpapersSubmenu.addItem(noWallpapersItem)
        } else {
            for bundle in installedWallpapers {
                let item = NSMenuItem(title: bundle.name, action: #selector(selectWallpaper(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = bundle
                wallpapersSubmenu.addItem(item)
            }
        }

        wallpapersItem.submenu = wallpapersSubmenu
        menu.addItem(wallpapersItem)

        let importItem = NSMenuItem(title: "Import Wallpaper...", action: #selector(importWallpaper), keyEquivalent: "i")
        importItem.target = self
        menu.addItem(importItem)

        menu.addItem(NSMenuItem.separator())

        let reloadItem = NSMenuItem(title: "Reload Current Wallpaper", action: #selector(reloadWallpaper), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let pauseItem = NSMenuItem(title: "Pause All", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())

        let preferencesItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit AetherDesk", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func statusItemClicked() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    @objc private func selectWallpaper(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? WallpaperBundle,
              let manager = wallpaperManager else { return }

        let screens = NSScreen.screens
        for screen in screens {
            if let displayID = screen.deviceDescription[NSScreen.DisplaysUUIDKey] as? String {
                let id = CGDirectDisplayID()
                manager.setWallpaper(bundle, for: id)
            }
        }

        if let primaryScreen = screens.first {
            manager.setWallpaper(bundle, for: primaryScreen.displayID ?? 0)
        }
    }

    @objc private func importWallpaper() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a Lively wallpaper folder to import"
        panel.prompt = "Import"

        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.performImport(from: url)
            }
        }
    }

    private func performImport(from url: URL) {
        do {
            let (bundle, classification) = try wallpaperImporter.importWallpaper(from: url)

            var message = "Wallpaper imported successfully."
            switch classification {
            case .allowed:
                break
            case .allowedWithLimits:
                message += " Some features were limited for performance."
            case .rejected:
                message += " However, it was rejected due to policy violations."
            }

            showNotification(title: "Import Complete", message: message)
            rebuildWallpapersSubmenu()
        } catch {
            showNotification(title: "Import Failed", message: error.localizedDescription)
        }
    }

    private func rebuildWallpapersSubmenu() {
        setupMenu()
    }

    @objc private func reloadWallpaper() {
        guard let manager = wallpaperManager else { return }

        for screen in NSScreen.screens {
            manager.reloadWallpaper(for: screen.displayID ?? 0)
        }
    }

    @objc private func togglePause() {
        guard let manager = wallpaperManager else { return }

        manager.pauseAll()
    }

    @objc private func showPreferences() {
        PreferencesWindowController.shared.showWindow(nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        NSUserNotificationCenter.default.deliver(notification)
    }
}
