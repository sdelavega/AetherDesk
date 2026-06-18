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
import Foundation
import UniformTypeIdentifiers
import UserNotifications

/// Menu-bar-only UI for ÆtherDesk. The app has no Dock presence (LSUIElement
/// in Info.plist); this controller is the primary user-facing surface.
///
/// Menu layout, per prompt:
///   ÆtherDesk
///   ─────────
///   Wallpapers ▸   (all available wallpapers, checkmark on current)
///   Import Wallpaper…
///   ─────────
///   Reload Current Wallpaper
///   Pause / Resume
///   Safe Mode (toggle)
///   ─────────
///   Preferences…
///   ─────────
///   Quit
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu: NSMenu
    private weak var wallpaperManager: WallpaperManager?
    private var importer: WallpaperImporter { WallpaperImporter.shared }
    private var cachedWallpapers: [WallpaperBundle]?

    // Submenu + items that need dynamic updates.
    private let wallpapersItem = NSMenuItem(title: "Wallpapers", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "p")
    private let safeModeItem = NSMenuItem(title: "Safe Mode", action: nil, keyEquivalent: "")

    private var isPaused = false
    private var isImporting = false

    init(wallpaperManager: WallpaperManager) {
        self.wallpaperManager = wallpaperManager
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()
        super.init()

        setupStatusItem()
        setupMenu()
        menu.delegate = self

        requestNotificationAuthIfPossible()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(wallpaperDidChange),
                                               name: Constants.Notifications.wallpaperDidChange,
                                               object: nil)

        #if !AETHERDESK_STORE
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleUpdateAvailable(_:)),
                                               name: Constants.Notifications.updateAvailable,
                                               object: nil)
        #endif
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Status item

    private func setupStatusItem() {
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "photo.on.rectangle.angled",
                                accessibilityDescription: "ÆtherDesk")
                ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "ÆtherDesk")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "ÆtherDesk"
        }
        statusItem.menu = menu
    }

    // MARK: Menu construction

    private func setupMenu() {
        menu.removeAllItems()

        let title = NSMenuItem(title: "ÆtherDesk", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        wallpapersItem.submenu = buildWallpapersSubmenu()
        menu.addItem(wallpapersItem)

        let importItem = NSMenuItem(title: "Import Wallpaper…",
                                    action: #selector(importWallpaper),
                                    keyEquivalent: "i")
        importItem.target = self
        menu.addItem(importItem)

        let openFolderItem = NSMenuItem(title: "Open Wallpaper Folder",
                                        action: #selector(openWallpaperFolder),
                                        keyEquivalent: "")
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        menu.addItem(.separator())

        let reloadItem = NSMenuItem(title: "Reload Current Wallpaper",
                                    action: #selector(reloadCurrent),
                                    keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        pauseItem.action = #selector(togglePause)
        pauseItem.target = self
        menu.addItem(pauseItem)

        safeModeItem.action = #selector(toggleSafeMode)
        safeModeItem.target = self
        menu.addItem(safeModeItem)

        menu.addItem(.separator())

        #if !AETHERDESK_STORE
        let checkUpdatesItem = NSMenuItem(title: "Check for Updates…",
                                          action: #selector(checkForUpdates),
                                          keyEquivalent: "u")
        checkUpdatesItem.target = self
        menu.addItem(checkUpdatesItem)
        #endif

        let preferencesItem = NSMenuItem(title: "Preferences…",
                                         action: #selector(showPreferences),
                                         keyEquivalent: ",")
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit ÆtherDesk",
                              action: #selector(quit),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func buildWallpapersSubmenu(from all: [WallpaperBundle]? = nil) -> NSMenu {
        let submenu = NSMenu()

        let list = all ?? importer.listWallpapers()
        if list.isEmpty {
            let placeholder = NSMenuItem(title: "No wallpapers installed", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            submenu.addItem(placeholder)
            return submenu
        }

        let primaryID = NSScreen.main?.displayID ?? 0
        let current = wallpaperManager?.currentBundle(for: primaryID)

        let bundled = list.filter { isBundled($0) }
        let imported = list.filter { !isBundled($0) }

        if !bundled.isEmpty {
            let header = NSMenuItem(title: "Built-in", action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)
            for bundle in bundled { submenu.addItem(wallpaperMenuItem(bundle, current: current)) }
            submenu.addItem(.separator())
        }

        if !imported.isEmpty {
            let header = NSMenuItem(title: "Imported", action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)
            for bundle in imported { submenu.addItem(wallpaperMenuItem(bundle, current: current)) }
        }

        return submenu
    }

    private func wallpaperMenuItem(_ bundle: WallpaperBundle,
                                   current: WallpaperBundle?) -> NSMenuItem {
        let item = NSMenuItem(title: bundle.name,
                              action: #selector(selectWallpaperOnAllDisplays(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = bundle
        if current?.id == bundle.id { item.state = .on }

        // Add a per-display submenu (prompt requirement) if >1 display.
        let screens = NSScreen.screens
        if screens.count > 1 {
            let perDisplay = NSMenu()

            let allDisplaysItem = NSMenuItem(title: "All Displays",
                                             action: #selector(selectWallpaperOnAllDisplays(_:)),
                                             keyEquivalent: "")
            allDisplaysItem.target = self
            allDisplaysItem.representedObject = bundle
            perDisplay.addItem(allDisplaysItem)
            perDisplay.addItem(.separator())

            for screen in screens {
                let displayID = screen.displayID
                let title = screen.localizedName
                let subitem = NSMenuItem(title: title,
                                         action: #selector(selectWallpaperForDisplay(_:)),
                                         keyEquivalent: "")
                subitem.target = self
                subitem.representedObject = SelectionTarget(bundle: bundle, displayID: displayID)
                if wallpaperManager?.currentBundle(for: displayID)?.id == bundle.id {
                    subitem.state = .on
                }
                perDisplay.addItem(subitem)
            }
            item.submenu = perDisplay
        }

        return item
    }

    private func isBundled(_ bundle: WallpaperBundle) -> Bool {
        guard let bundledDir = importer.bundledWallpapersDirectory else { return false }
        return bundle.baseURL.path.hasPrefix(bundledDir.path)
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        let currentList = importer.listWallpapers()
        let needsRebuild = cachedWallpapers == nil || cachedWallpapers!.count != currentList.count
            || !Set(cachedWallpapers!.map(\.id)).isSuperset(of: currentList.map(\.id))
        if needsRebuild {
            cachedWallpapers = currentList
            wallpapersItem.submenu = buildWallpapersSubmenu(from: currentList)
        } else {
            updateCheckmarks(in: wallpapersItem.submenu, from: currentList)
        }
        pauseItem.title = isPaused ? "Resume" : "Pause"
        safeModeItem.state = (wallpaperManager?.isSafeMode ?? false) ? .on : .off
    }

    private func updateCheckmarks(in submenu: NSMenu?, from bundles: [WallpaperBundle]) {
        guard let submenu else { return }
        let primaryID = NSScreen.main?.displayID ?? 0
        let current = wallpaperManager?.currentBundle(for: primaryID)
        for item in submenu.items {
            guard let bundle = item.representedObject as? WallpaperBundle else { continue }
            item.state = (current?.id == bundle.id) ? .on : .off
            if let perDisplay = item.submenu {
                for subitem in perDisplay.items {
                    if let sel = subitem.representedObject as? SelectionTarget {
                        subitem.state = (wallpaperManager?.currentBundle(for: sel.displayID)?.id == bundle.id) ? .on : .off
                    } else if subitem.representedObject is WallpaperBundle {
                        subitem.state = (current?.id == bundle.id) ? .on : .off
                    }
                }
            }
        }
    }

    // MARK: Actions

    @objc private func selectWallpaperOnAllDisplays(_ sender: NSMenuItem) {
        guard let bundle = sender.representedObject as? WallpaperBundle,
              let manager = wallpaperManager else { return }
        manager.setWallpaperOnAllDisplays(bundle)
    }

    @objc private func selectWallpaperForDisplay(_ sender: NSMenuItem) {
        guard let sel = sender.representedObject as? SelectionTarget,
              let manager = wallpaperManager else { return }
        manager.setWallpaper(sel.bundle, for: sel.displayID)
    }

    @objc private func importWallpaper() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "zip"),
            UTType(filenameExtension: "lively")
        ].compactMap { $0 }
        panel.message = "Select a Lively wallpaper folder, .zip, or .lively package to import"
        panel.prompt = "Import"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.performImport(from: url)
        }
    }

    private func performImport(from url: URL) {
        guard !isImporting else { return }
        isImporting = true
        importer.importWallpaper(from: url) { [weak self] result in
            guard let self else { return }
            self.isImporting = false
            switch result {
            case .success((_, let classification)):
                importer.invalidateCache()
                let (title, body) = Self.importReport(for: classification)
                if case .allowedWithLimits = classification {
                    self.showAlert(style: .informational, title: title, body: body)
                } else {
                    self.postNotification(title: title, body: body)
                }
            case .failure(let error):
                self.showAlert(style: .critical, title: "Import Failed", body: error.localizedDescription)
            }
        }
    }

    @objc private func openWallpaperFolder() {
        let dir = importer.wallpapersDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func reloadCurrent() {
        wallpaperManager?.reloadAll()
    }

    @objc private func togglePause() {
        guard let manager = wallpaperManager else { return }
        isPaused.toggle()
        if isPaused { manager.pauseAll() } else { manager.resumeAll() }
    }

    @objc private func toggleSafeMode() {
        guard let manager = wallpaperManager else { return }
        manager.setSafeMode(!manager.isSafeMode)
    }

    @objc private func showPreferences() {
        NSApp.activate(ignoringOtherApps: true)
        PreferencesWindowController.shared.showWindow(nil)
    }

    #if !AETHERDESK_STORE
    @objc private func checkForUpdates() {
        UpdateManager.shared.checkForUpdatesInteractively()
    }

    @objc private func handleUpdateAvailable(_ note: Notification) {
        guard let release = note.object as? UpdateManager.GitHubRelease else { return }
        UpdateManager.shared.presentUpdateAlert(release)
    }
    #endif

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func wallpaperDidChange() {
        // Just refresh checkmarks on next menu open — no directory rescan needed.
    }

    // MARK: Notifications

    private func requestNotificationAuthIfPossible() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert]) { _, _ in }
        }
    }

    private func showAlert(style: NSAlert.Style, title: String, body: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func postNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private static func importReport(for classification: WallpaperClassification) -> (String, String) {
        switch classification {
        case .allowed:
            return ("Wallpaper imported", "The wallpaper was allowed without constraints.")
        case .allowedWithLimits(let fps, let budget, let warnings):
            let warningText = warnings.isEmpty ? "" : " Warnings: " + warnings.prefix(3).joined(separator: "; ")
            return ("Wallpaper imported with limits",
                    "FPS capped at \(fps). Network budget: \(budget) req/min.\(warningText)")
        case .rejected(let reason):
            return ("Wallpaper rejected", reason)
        }
    }

    // MARK: Types

    private struct SelectionTarget {
        let bundle: WallpaperBundle
        let displayID: CGDirectDisplayID
    }
}
