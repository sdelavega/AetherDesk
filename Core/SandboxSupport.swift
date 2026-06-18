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

import Foundation
import os.log

/// Scaffolding for App Sandbox support. All methods are no-ops when the app
/// is running unsandboxed. When sandbox is enabled (entitlements flip), call
/// `migrateIfNeeded()` once at launch from AppDelegate.
///
/// Migration moves the pre-sandbox wallpaper library from
///   ~/Library/Application Support/ÆtherDesk/Wallpapers/
/// into the sandbox container at
///   ~/Library/Containers/com.sdelavega.AetherDesk/Data/Library/Application Support/ÆtherDesk/Wallpapers/
///
/// Security-scoped bookmark helpers are provided for persistent access to
/// user-selected import directories across launches.
enum SandboxSupport {

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    // MARK: - First-launch migration

    /// Moves wallpaper data from the pre-sandbox location into the sandbox
    /// container. No-op when unsandboxed or when migration has already run.
    static func migrateIfNeeded() {
        guard isSandboxed else { return }

        let defaults = UserDefaults.standard
        let migrationKey = "AetherDesk.sandboxMigration.v1"
        if defaults.bool(forKey: migrationKey) { return }

        let fm = FileManager.default

        // When sandboxed, FileManager.urls(for: .applicationSupportDirectory)
        // returns the container path for both old and new — making migration a
        // no-op. Derive the pre-sandbox location from the real user home.
        let realHome = URL(fileURLWithPath: "/Users/\(NSUserName())")
        let oldBase = realHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(Constants.appName, isDirectory: true)

        guard fm.fileExists(atPath: oldBase.path) else {
            defaults.set(true, forKey: migrationKey)
            return
        }

        // newBase resolves to the sandbox container's Application Support.
        let newBase = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(Constants.appName, isDirectory: true)

        guard let newBase = newBase, newBase.path != oldBase.path else {
            Logger.app.info("ÆtherDesk SandboxSupport: could not locate sandbox container — skipping migration")
            return
        }

        if !fm.fileExists(atPath: newBase.path) {
            do {
                try fm.createDirectory(at: newBase, withIntermediateDirectories: true)
            } catch {
                Logger.app.error("ÆtherDesk SandboxSupport: failed to create container directory: \(error.localizedDescription)")
                return
            }
        }

        let oldWallpapers = oldBase.appendingPathComponent(Constants.Directories.wallpapersSubfolder)
        let newWallpapers = newBase.appendingPathComponent(Constants.Directories.wallpapersSubfolder)

        if fm.fileExists(atPath: oldWallpapers.path) && !fm.fileExists(atPath: newWallpapers.path) {
            do {
                try fm.moveItem(at: oldWallpapers, to: newWallpapers)
                Logger.app.info("ÆtherDesk SandboxSupport: migrated wallpapers to sandbox container")
            } catch {
                Logger.app.error("ÆtherDesk SandboxSupport: migration failed: \(error.localizedDescription)")
                return
            }
        }

        let oldStore = oldBase.appendingPathComponent("AetherDesk.propertyStore")
        if fm.fileExists(atPath: oldStore.path) {
            let newStore = newBase.appendingPathComponent("AetherDesk.propertyStore")
            if !fm.fileExists(atPath: newStore.path) {
                try? fm.moveItem(at: oldStore, to: newStore)
            }
        }

        defaults.set(true, forKey: migrationKey)
    }

    // MARK: - Security-scoped bookmarks

    private static let bookmarkKey = "AetherDesk.securityScopedBookmarks"

    /// Creates a security-scoped bookmark for the given directory URL (typically
    /// from an NSOpenPanel). Returns nil if bookmark creation fails.
    static func createBookmark(for url: URL) -> Data? {
        guard isSandboxed else { return nil }
        do {
            return try url.bookmarkData(options: .withSecurityScope,
                                        includingResourceValuesForKeys: nil,
                                        relativeTo: nil)
        } catch {
            Logger.app.error("ÆtherDesk SandboxSupport: bookmark creation failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolves a previously stored bookmark back into a URL and starts
    /// security-scoped access. Call `stopAccessingSecurityScopedResource()`
    /// on the returned URL when done.
    static func resolveBookmark(_ data: Data) -> URL? {
        guard isSandboxed else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale)
            if url.startAccessingSecurityScopedResource() {
                return url
            }
            return nil
        } catch {
            Logger.app.error("ÆtherDesk SandboxSupport: bookmark resolution failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Persists a bookmark for an import source directory so it can be
    /// re-accessed across launches.
    static func saveBookmark(_ data: Data, forKey key: String) {
        guard isSandboxed else { return }
        var bookmarks = loadAllBookmarks()
        bookmarks[key] = data
        if let encoded = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(encoded, forKey: bookmarkKey)
        }
    }

    /// Loads a previously saved bookmark for the given key.
    static func loadBookmark(forKey key: String) -> Data? {
        loadAllBookmarks()[key]
    }

    private static func loadAllBookmarks() -> [String: Data] {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey),
              let dict = try? JSONDecoder().decode([String: Data].self, from: data) else {
            return [:]
        }
        return dict
    }
}
