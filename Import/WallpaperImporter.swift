import Foundation

enum WallpaperClassification {
    case allowed
    case allowedWithLimits(fps: Int, networkBudget: Int)
    case rejected(reason: String)
}

class WallpaperImporter {

    private let validator = WallpaperValidator()
    private let fileManager = FileManager.default

    var wallpapersDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(Constants.appName).appendingPathComponent(Constants.Directories.wallpapersSubfolder)
    }

    init() {
        createWallpapersDirectoryIfNeeded()
    }

    func importWallpaper(from sourceURL: URL) throws -> (WallpaperBundle, WallpaperClassification) {
        let classification = validator.validate(at: sourceURL)

        switch classification {
        case .rejected(let reason):
            throw ImportError.rejected(reason: reason)
        default:
            break
        }

        let bundle = try copyToWallpapersDirectory(from: sourceURL)

        return (bundle, classification)
    }

    func importWallpaperFromFolder(_ folderURL: URL) throws -> (WallpaperBundle, WallpaperClassification) {
        return try importWallpaper(from: folderURL)
    }

    func listWallpapers() -> [WallpaperBundle] {
        var bundles: [WallpaperBundle] = []

        guard let contents = try? fileManager.contentsOfDirectory(at: wallpapersDirectory, includingPropertiesForKeys: nil) else {
            return bundles
        }

        for item in contents {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory), isDirectory.boolValue {
                if let bundle = WallpaperBundle(from: item) {
                    bundles.append(bundle)
                }
            }
        }

        return bundles
    }

    func deleteWallpaper(_ bundle: WallpaperBundle) throws {
        try fileManager.removeItem(at: bundle.baseURL)
    }

    private func copyToWallpapersDirectory(from sourceURL: URL) throws -> WallpaperBundle {
        if !fileManager.fileExists(atPath: wallpapersDirectory.path) {
            try createWallpapersDirectoryIfNeeded()
        }

        let destinationName = UUID().uuidString
        let destinationURL = wallpapersDirectory.appendingPathComponent(destinationName)

        try fileManager.copyItem(at: sourceURL, to: destinationURL)

        guard let bundle = WallpaperBundle(from: destinationURL) else {
            try? fileManager.removeItem(at: destinationURL)
            throw ImportError.invalidBundle
        }

        return bundle
    }

    private func createWallpapersDirectoryIfNeeded() throws {
        if !fileManager.fileExists(atPath: wallpapersDirectory.path) {
            try fileManager.createDirectory(at: wallpapersDirectory, withIntermediateDirectories: true)
        }
    }
}

enum ImportError: Error {
    case rejected(reason: String)
    case invalidBundle
    case copyFailed
    case directoryCreationFailed
}
