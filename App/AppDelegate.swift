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

/// Top-level app delegate. Runs as an accessory app (menu-bar only, no Dock
/// presence — see Info.plist LSUIElement).
final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var wallpaperManager: WallpaperManager?
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Migrate pre-sandbox wallpaper data into the sandbox container on first
        // launch of the App Store build. No-op when running unsandboxed (OSS).
        SandboxSupport.migrateIfNeeded()

        let manager = WallpaperManager()
        self.wallpaperManager = manager
        self.menuBarController = MenuBarController(wallpaperManager: manager)

        // Compile (or load from cache) the content blocker rule list before
        // starting any wallpaper WebViews. On subsequent launches this is a
        // cache hit and resolves in milliseconds; first launch compiles from
        // the embedded JSON, which takes well under a second for our small list.
        ContentRuleListManager.shared.prepare {
            DispatchQueue.global(qos: .userInitiated).async {
                let available = WallpaperImporter.shared.listWallpapers()
                let fallback = WallpaperImporter.shared.listBundledWallpapers().first
                DispatchQueue.main.async {
                    manager.startAndRestore(availableBundles: available, fallback: fallback)
                    #if !AETHERDESK_STORE
                    UpdateManager.shared.startPeriodicChecks()
                    #endif
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wallpaperManager?.stopAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
