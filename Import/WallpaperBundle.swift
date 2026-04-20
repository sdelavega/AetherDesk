import Foundation

enum WallpaperType: String {
    case web = "web"
    case video = "video"
    case image = "image"
    case unknown = "unknown"
}

class WallpaperBundle {

    let id: UUID
    let name: String
    let baseURL: URL
    let type: WallpaperType

    let livelyInfo: LivelyInfo?
    let properties: [LivelyProperty]?

    var indexURL: URL? {
        return baseURL.appendingPathComponent(Constants.Keys.indexFile)
    }

    var videoURL: URL? {
        let videoExtensions = ["mp4", "mov", "webm", "gif", "webp"]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else {
            return nil
        }

        for file in contents {
            if videoExtensions.contains(file.pathExtension.lowercased()) {
                return file
            }
        }
        return nil
    }

    var imageURL: URL? {
        let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp"]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: baseURL, includingPropertiesForKeys: nil) else {
            return nil
        }

        for file in contents {
            if imageExtensions.contains(file.pathExtension.lowercased()) && file.path.range(of: "preview", options: .caseInsensitive) == nil {
                return file
            }
        }
        return nil
    }

    init?(from url: URL) {
        guard let parsedID = UUID(uuidString: url.lastPathComponent) else {
            return nil
        }

        self.id = parsedID
        self.name = url.lastPathComponent
        self.baseURL = url

        let infoParser = LivelyInfoParser()
        self.livelyInfo = infoParser.parse(from: url)

        let propertiesParser = LivelyPropertiesParser()
        self.properties = propertiesParser.parse(from: url)

        // Precompute resource URLs without using self to avoid accessing properties before initialization
        let foundVideoURL: URL? = {
            let videoExtensions = ["mp4", "mov", "webm", "gif", "webp"]
            guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
                return nil
            }
            for file in contents {
                if videoExtensions.contains(file.pathExtension.lowercased()) {
                    return file
                }
            }
            return nil
        }()

        let foundImageURL: URL? = {
            let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp"]
            guard let contents = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
                return nil
            }
            for file in contents {
                if imageExtensions.contains(file.pathExtension.lowercased()) && file.path.range(of: "preview", options: .caseInsensitive) == nil {
                    return file
                }
            }
            return nil
        }()

        if FileManager.default.fileExists(atPath: url.appendingPathComponent(Constants.Keys.indexFile).path) {
            self.type = .web
        } else if let _ = foundVideoURL {
            self.type = .video
        } else if let _ = foundImageURL {
            self.type = .image
        } else if let info = livelyInfo, let typeString = info.type {
            switch typeString.lowercased() {
            case "video", "gif":
                self.type = .video
            case "image", "picture":
                self.type = .image
            default:
                self.type = .unknown
            }
        } else {
            self.type = .unknown
        }
    }
}

