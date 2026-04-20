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
        let hasIndex = FileManager.default.fileExists(
            atPath: url.appendingPathComponent(Constants.Keys.indexFile).path)
        let foundVideo = WallpaperBundle.firstFile(in: url,
                                                   withExtensions: WallpaperBundle.videoExtensions)
        let foundImage = WallpaperBundle.firstFile(in: url,
                                                   withExtensions: WallpaperBundle.imageExtensions,
                                                   excludingNameContaining: "preview")

        if hasIndex {
            self.type = .web
        } else if foundVideo != nil {
            self.type = .video
        } else if foundImage != nil {
            self.type = .image
        } else if let typeString = livelyInfo?.type?.lowercased() {
            switch typeString {
            case "video", "gif":            self.type = .video
            case "image", "picture":        self.type = .image
            case "web", "html", "webpage":  self.type = .web
            default:                        self.type = .unknown
            }
        } else {
            self.type = .unknown
        }
    }

    // MARK: Resource URLs

    var indexURL: URL? {
        let url = baseURL.appendingPathComponent(Constants.Keys.indexFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    var videoURL: URL? {
        WallpaperBundle.firstFile(in: baseURL, withExtensions: WallpaperBundle.videoExtensions)
    }

    var imageURL: URL? {
        WallpaperBundle.firstFile(in: baseURL,
                                  withExtensions: WallpaperBundle.imageExtensions,
                                  excludingNameContaining: "preview")
    }

    var previewImageURL: URL? {
        // LivelyInfo.Preview takes precedence if present.
        if let preview = livelyInfo?.Preview {
            let url = baseURL.appendingPathComponent(preview)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Otherwise look for a file whose name contains "preview".
        let contents = (try? FileManager.default.contentsOfDirectory(at: baseURL,
                                                                     includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.lastPathComponent.localizedCaseInsensitiveContains("preview") }
    }

    // MARK: Helpers

    private static let videoExtensions = ["mp4", "mov", "m4v", "webm"]
    private static let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

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
