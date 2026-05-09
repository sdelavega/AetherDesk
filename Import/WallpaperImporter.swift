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
import AppKit

/// Structured result of screening a candidate wallpaper bundle.
/// Returned alongside the imported bundle so the UI can surface a human
/// readable import report (prompt requirement).
enum WallpaperClassification {
    case allowed
    case allowedWithLimits(fps: Int, networkBudget: Int, warnings: [String])
    case rejected(reason: String)
}

enum ImportError: Error, LocalizedError {
    case rejected(reason: String)
    case invalidBundle
    case unsupportedImportType
    case archiveExtractionFailed(underlying: Error)
    case copyFailed(underlying: Error)
    case directoryCreationFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .rejected(let r):            return "Wallpaper rejected: \(r)"
        case .invalidBundle:              return "Invalid wallpaper bundle"
        case .unsupportedImportType:       return "Select a wallpaper folder, .zip, or .lively package"
        case .archiveExtractionFailed(let e): return "Archive extraction failed: \(e.localizedDescription)"
        case .copyFailed(let e):          return "Copy failed: \(e.localizedDescription)"
        case .directoryCreationFailed(let e): return "Could not create wallpaper directory: \(e.localizedDescription)"
        }
    }
}

/// Imports wallpaper bundles from disk into the user's library, and also
/// exposes the read-only bundled (in-app) sample wallpapers.
final class WallpaperImporter {

    static let shared = WallpaperImporter()

    private let validator = WallpaperValidator()
    private let runtimePolicyStore = RuntimePolicyStore.shared
    private let propertyStore = PropertyStore()
    private let fileManager = FileManager.default
    private var cachedWallpapers: [WallpaperBundle]?

    /// User-writable library in ~/Library/Application Support/ÆtherDesk/Wallpapers.
    var wallpapersDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory,
                                          in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(Constants.appName, isDirectory: true)
            .appendingPathComponent(Constants.Directories.wallpapersSubfolder, isDirectory: true)
    }

    /// Read-only sample wallpapers shipped inside the app bundle's Resources.
    var bundledWallpapersDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Wallpapers", isDirectory: true)
    }

    init() {
        // Non-throwing; log on failure. Import-time operations will retry.
        try? createWallpapersDirectoryIfNeeded()
    }

    // MARK: Import

    func importWallpaper(from sourceURL: URL) throws
        -> (bundle: WallpaperBundle, classification: WallpaperClassification)
    {
        let prepared = try prepareImportSource(sourceURL)
        defer {
            if let tempDirectory = prepared.tempDirectory {
                try? fileManager.removeItem(at: tempDirectory)
            }
        }

        let classification = validator.validate(at: prepared.bundleURL)

        if case .rejected(let reason) = classification {
            throw ImportError.rejected(reason: reason)
        }

        let bundle = try copyToWallpapersDirectory(from: prepared.bundleURL)
        runtimePolicyStore.save(WallpaperRuntimePolicy(classification: classification),
                                for: bundle.id)
        invalidateCache()
        return (bundle, classification)
    }

    /// Async variant that performs all I/O on a background queue and
    /// calls back on the main queue. Use this from UI code to avoid
    /// freezing the app during large archive extraction or file copies.
    func importWallpaper(from sourceURL: URL,
                         completion: @escaping (Result<(WallpaperBundle, WallpaperClassification), Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result = try self.importWallpaper(from: sourceURL)
                DispatchQueue.main.async { completion(.success(result)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: Listing

    /// All available wallpapers: bundled samples + user-imported.
    /// Results are cached; call `invalidateCache()` after import/delete.
    func listWallpapers() -> [WallpaperBundle] {
        if let cached = cachedWallpapers { return cached }
        let all = listBundledWallpapers() + listImportedWallpapers()
        cachedWallpapers = all
        return all
    }

    func invalidateCache() {
        cachedWallpapers = nil
    }

    /// User-imported wallpapers from Application Support.
    func listImportedWallpapers() -> [WallpaperBundle] {
        directoryBundles(at: wallpapersDirectory)
    }

    /// Read-only sample wallpapers shipped with the app.
    func listBundledWallpapers() -> [WallpaperBundle] {
        guard let dir = bundledWallpapersDirectory else { return [] }
        return directoryBundles(at: dir)
    }

    private func directoryBundles(at dir: URL) -> [WallpaperBundle] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var out: [WallpaperBundle] = []
        for item in contents {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            if let b = WallpaperBundle(from: item) { out.append(b) }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func deleteWallpaper(_ bundle: WallpaperBundle) throws {
        // Refuse to delete bundled (read-only) wallpapers.
        if let bundled = bundledWallpapersDirectory,
           bundle.baseURL.path.hasPrefix(bundled.path) {
            throw ImportError.invalidBundle
        }
        try fileManager.removeItem(at: bundle.baseURL)
        runtimePolicyStore.delete(for: bundle.id)
        GeolocationPermissionStore.shared.delete(for: bundle.id)
        propertyStore.delete(for: bundle.id)
        invalidateCache()
        // Notify WallpaperManager so it can tear down any live runtime that is
        // currently showing this bundle, rather than waiting until next launch.
        NotificationCenter.default.post(
            name: Constants.Notifications.wallpaperDeleted,
            object: nil,
            userInfo: ["bundleID": bundle.id.uuidString])
    }

    // MARK: Plumbing

    private func prepareImportSource(_ sourceURL: URL) throws -> (bundleURL: URL, tempDirectory: URL?) {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return (sourceURL, nil)
        }

        guard ["zip", "lively"].contains(sourceURL.pathExtension.lowercased()) else {
            throw ImportError.unsupportedImportType
        }

        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("AetherDeskImport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        do {
            try extractArchive(sourceURL, to: tempDirectory)
            let bundleURL = try resolvedBundleRoot(in: tempDirectory)
            return (bundleURL, tempDirectory)
        } catch {
            try? fileManager.removeItem(at: tempDirectory)
            if let importError = error as? ImportError {
                throw importError
            }
            throw ImportError.archiveExtractionFailed(underlying: error)
        }
    }

    private func extractArchive(_ archiveURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ImportError.archiveExtractionFailed(underlying: error)
        }

        guard process.terminationStatus == 0 else {
            throw ImportError.archiveExtractionFailed(
                underlying: NSError(domain: "ÆtherDesk.Import",
                                    code: Int(process.terminationStatus),
                                    userInfo: [NSLocalizedDescriptionKey: "ditto exited with status \(process.terminationStatus)"])
            )
        }

        try sanitizeExtractedContent(at: destinationURL)
    }

    /// Walks the extracted directory tree and removes any files or symlinks that
    /// resolve outside the destination directory (zip slip / symlink traversal).
    private func sanitizeExtractedContent(at rootURL: URL) throws {
        let rootPath = rootURL.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return }

        var violations: [URL] = []

        for case let itemURL as URL in enumerator {
            let resolved = itemURL.resolvingSymlinksInPath().standardizedFileURL
            let resolvedPath = resolved.path
            if resolvedPath != rootPath && !resolvedPath.hasPrefix(rootPath + "/") {
                Logger.app.info("ÆtherDesk: zip-slip detected — removing entry that resolves to \(resolvedPath)")
                violations.append(itemURL)
                continue
            }

            let resourceValues = try? itemURL.resourceValues(forKeys: Set(keys))
            if resourceValues?.isSymbolicLink == true {
                let destPath = try? fileManager.destinationOfSymbolicLink(atPath: itemURL.path)
                if let destPath = destPath {
                    let destResolved = URL(fileURLWithPath: destPath, relativeTo: itemURL)
                        .resolvingSymlinksInPath().standardizedFileURL.path
                    if destResolved != rootPath && !destResolved.hasPrefix(rootPath + "/") {
                        Logger.app.info("ÆtherDesk: symlink escape detected — removing symlink at \(itemURL.path)")
                        violations.append(itemURL)
                    }
                }
            }
        }

        for url in violations {
            try? fileManager.removeItem(at: url)
        }

        if !violations.isEmpty {
            Logger.app.info("ÆtherDesk: removed \(violations.count) zip-slip/symlink-escape entries from extracted archive")
        }
    }

    private func resolvedBundleRoot(in extractedDirectory: URL) throws -> URL {
        if WallpaperBundle(from: extractedDirectory) != nil {
            return extractedDirectory
        }

        let contents = try fileManager.contentsOfDirectory(
            at: extractedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let directories = contents.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        if directories.count == 1, WallpaperBundle(from: directories[0]) != nil {
            return directories[0]
        }

        if let bundleDirectory = directories.first(where: { WallpaperBundle(from: $0) != nil }) {
            return bundleDirectory
        }

        throw ImportError.invalidBundle
    }

    private func copyToWallpapersDirectory(from sourceURL: URL) throws -> WallpaperBundle {
        try createWallpapersDirectoryIfNeeded()

        let destinationName = UUID().uuidString
        let destinationURL = wallpapersDirectory
            .appendingPathComponent(destinationName, isDirectory: true)

        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw ImportError.copyFailed(underlying: error)
        }

        guard let bundle = WallpaperBundle(from: destinationURL) else {
            try? fileManager.removeItem(at: destinationURL)
            throw ImportError.invalidBundle
        }
        return bundle
    }

    private func createWallpapersDirectoryIfNeeded() throws {
        if !fileManager.fileExists(atPath: wallpapersDirectory.path) {
            do {
                try fileManager.createDirectory(at: wallpapersDirectory,
                                                withIntermediateDirectories: true)
            } catch {
                throw ImportError.directoryCreationFailed(underlying: error)
            }
        }
    }
}
