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

enum WallpaperType: String, Codable {
    case web
    case video
    case image
    case unknown
}

/// Normalized in-memory representation of a wallpaper "bundle" (a directory
/// that contains a LivelyInfo.json + an index.html / video / image).
///
/// `id` is derived from the folder name:
///   - if the folder is named after a UUID (as imported bundles are), we use
///     that UUID directly so property overrides persist across launches;
///   - otherwise we deterministically hash the absolute path so built-in
///     sample wallpapers (e.g. "MatrixRain") still get a stable id.
final class WallpaperBundle {

    let id: UUID
    let name: String
    let baseURL: URL
    let type: WallpaperType
    let livelyInfo: LivelyInfo?
    let properties: [LivelyProperty]?

    init?(from url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            return nil
        }

        self.id = WallpaperBundle.stableID(for: url)
        self.baseURL = url
        self.livelyInfo = LivelyInfoParser().parse(from: url)
        self.properties = LivelyPropertiesParser().parse(from: url)
        self.name = livelyInfo?.Title ?? url.lastPathComponent

        // Resolve resource URLs without touching `self.*` properties before init ends.
        // Lively bundles often declare the real entry file in FileName instead
        // of using ÆtherDesk's conventional index.html / first-media fallback.
        let declaredResource = WallpaperBundle.declaredResourceURL(from: livelyInfo?.FileName,
                                                                   in: url)
        let hasIndex = FileManager.default.fileExists(
            atPath: url.appendingPathComponent(Constants.Keys.indexFile).path)
        let foundVideo = WallpaperBundle.firstFile(in: url,
                                                   withExtensions: WallpaperBundle.videoExtensions)
        let foundImage = WallpaperBundle.firstFile(in: url,
                                                   withExtensions: WallpaperBundle.imageExtensions,
                                                   excludingNameContaining: "preview")

        if let declaredResource,
           WallpaperBundle.webExtensions.contains(declaredResource.pathExtension.lowercased()) {
            self.type = .web
        } else if let declaredResource,
                  WallpaperBundle.videoExtensions.contains(declaredResource.pathExtension.lowercased()) {
            self.type = .video
        } else if let declaredResource,
                  WallpaperBundle.imageExtensions.contains(declaredResource.pathExtension.lowercased()) {
            self.type = .image
        } else if let typeString = livelyInfo?.type?.lowercased() {
            switch typeString {
            case "video", "gif":            self.type = .video
            case "image", "picture":        self.type = .image
            case "web", "html", "webpage":  self.type = .web
            default:                        self.type = .unknown
            }
        } else if hasIndex {
            self.type = .web
        } else if foundVideo != nil {
            self.type = .video
        } else if foundImage != nil {
            self.type = .image
        } else {
            self.type = .unknown
        }
    }

    // MARK: Resource URLs

    private var _cachedIndexURL: URL?
    private var _cachedVideoURL: URL?
    private var _cachedImageURL: URL?
    private var _cachedPreviewImageURL: URL?
    private var _didResolveIndexURL = false
    private var _didResolveVideoURL = false
    private var _didResolveImageURL = false
    private var _didResolvePreviewImageURL = false

    var indexURL: URL? {
        if _didResolveIndexURL { return _cachedIndexURL }
        _didResolveIndexURL = true
        if let declared = Self.declaredResourceURL(from: livelyInfo?.FileName, in: baseURL),
           Self.webExtensions.contains(declared.pathExtension.lowercased()) {
            _cachedIndexURL = declared
        } else {
            let url = baseURL.appendingPathComponent(Constants.Keys.indexFile)
            _cachedIndexURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return _cachedIndexURL
    }

    var videoURL: URL? {
        if _didResolveVideoURL { return _cachedVideoURL }
        _didResolveVideoURL = true
        if let declared = Self.declaredResourceURL(from: livelyInfo?.FileName, in: baseURL),
           Self.videoExtensions.contains(declared.pathExtension.lowercased()) {
            _cachedVideoURL = declared
        } else {
            _cachedVideoURL = WallpaperBundle.firstFile(in: baseURL, withExtensions: WallpaperBundle.videoExtensions)
        }
        return _cachedVideoURL
    }

    var imageURL: URL? {
        if _didResolveImageURL { return _cachedImageURL }
        _didResolveImageURL = true
        if let declared = Self.declaredResourceURL(from: livelyInfo?.FileName, in: baseURL),
           Self.imageExtensions.contains(declared.pathExtension.lowercased()),
           !declared.lastPathComponent.localizedCaseInsensitiveContains("preview") {
            _cachedImageURL = declared
        } else {
            _cachedImageURL = WallpaperBundle.firstFile(in: baseURL,
                                             withExtensions: WallpaperBundle.imageExtensions,
                                             excludingNameContaining: "preview")
        }
        return _cachedImageURL
    }

    var previewImageURL: URL? {
        if _didResolvePreviewImageURL { return _cachedPreviewImageURL }
        _didResolvePreviewImageURL = true
        // LivelyInfo.Preview takes precedence if present, routed through the
        // same traversal-safe resolver as FileName so a malicious Preview
        // field can't escape the bundle directory.
        if let preview = livelyInfo?.Preview,
           let url = Self.declaredResourceURL(from: preview, in: baseURL),
           Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            _cachedPreviewImageURL = url
            return url
        }
        // Otherwise look for an image file whose name contains "preview".
        let contents = (try? FileManager.default.contentsOfDirectory(at: baseURL,
                                                                     includingPropertiesForKeys: nil)) ?? []
        _cachedPreviewImageURL = contents.first {
            $0.lastPathComponent.localizedCaseInsensitiveContains("preview") &&
            Self.imageExtensions.contains($0.pathExtension.lowercased())
        }
        return _cachedPreviewImageURL
    }

    // MARK: Helpers

    private static let webExtensions = ["html", "htm"]
    private static let videoExtensions = ["mp4", "mov", "m4v", "webm"]
    private static let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    private static func declaredResourceURL(from fileName: String?, in dir: URL) -> URL? {
        guard var fileName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fileName.isEmpty else {
            return nil
        }

        fileName = fileName.replacingOccurrences(of: "\\", with: "/")
        guard !fileName.hasPrefix("/"),
              !fileName.contains(":") else {
            return nil
        }

        let pathComponents = fileName.split(separator: "/").map(String.init)
        guard !pathComponents.isEmpty,
              !pathComponents.contains("..") else {
            return nil
        }

        let base = dir.standardizedFileURL
        let candidate = pathComponents.reduce(base) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL

        guard candidate.path.hasPrefix(base.path + "/"),
              FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    private static func firstFile(in dir: URL,
                                  withExtensions exts: [String],
                                  excludingNameContaining excluded: String? = nil) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        return contents.first {
            guard exts.contains($0.pathExtension.lowercased()) else { return false }
            if let excluded = excluded,
               $0.lastPathComponent.localizedCaseInsensitiveContains(excluded) {
                return false
            }
            return true
        }
    }

    /// Derive a stable UUID from a folder path. If the folder name already
    /// parses as a UUID (imported bundles) we use it directly; otherwise we
    /// derive a deterministic UUID v5-style value from the absolute path.
    private static func stableID(for url: URL) -> UUID {
        if let uuid = UUID(uuidString: url.lastPathComponent) {
            return uuid
        }
        let path = url.resolvingSymlinksInPath().path
        var bytes = [UInt8](repeating: 0, count: 16)
        var hash: UInt64 = 1469598103934665603 // FNV-1a offset basis
        let prime: UInt64 = 1099511628211
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        // Splat the 64-bit hash across 16 bytes.
        for i in 0..<8 {
            bytes[i] = UInt8((hash >> (8 * i)) & 0xFF)
            bytes[i + 8] = UInt8((hash >> (8 * (7 - i))) & 0xFF)
        }
        // Tag as RFC 4122 v4-ish so it looks like a valid UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
