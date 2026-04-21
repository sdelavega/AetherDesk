import Testing
import Foundation

@Suite("WallpaperBundle") struct WallpaperBundleTests {

    // Creates a temp bundle and returns its URL. Caller is responsible for
    // cleanup via `try? FileManager.default.removeItem(at: url.deletingLastPathComponent())`.
    private func makeBundle(
        name: String = "TestBundle",
        files: [String: String] = [:],
        binaryFiles: [String] = [],
        livelyInfo: [String: Any]? = nil
    ) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AetherDeskTests-\(UUID().uuidString)")
        let dir = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (filename, content) in files {
            try content.write(to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        for filename in binaryFiles {
            try Data().write(to: dir.appendingPathComponent(filename))
        }
        if let info = livelyInfo {
            let data = try JSONSerialization.data(withJSONObject: info)
            try data.write(to: dir.appendingPathComponent("LivelyInfo.json"))
        }
        return dir
    }

    // MARK: ID derivation

    @Test func idFromUUIDFolderName() throws {
        let knownUUID = UUID()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("AetherDeskTests-\(UUID().uuidString)")
        let dir = base.appendingPathComponent(knownUUID.uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "".write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let bundle = try #require(WallpaperBundle(from: dir))
        #expect(bundle.id == knownUUID)
    }

    @Test func idFromNonUUIDFolderIsStable() throws {
        let dir = try makeBundle(name: "MatrixRain", files: ["index.html": ""])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let b1 = try #require(WallpaperBundle(from: dir))
        let b2 = try #require(WallpaperBundle(from: dir))
        #expect(b1.id == b2.id)
        // Must not accidentally parse folder name as UUID
        #expect(UUID(uuidString: "MatrixRain") == nil)
    }

    // MARK: Type resolution

    @Test func typeIsWebForIndexHtml() throws {
        let dir = try makeBundle(files: ["index.html": "<html/>"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let bundle = try #require(WallpaperBundle(from: dir))
        #expect(bundle.type == .web)
    }

    @Test func typeIsVideoForMp4() throws {
        let dir = try makeBundle(binaryFiles: ["video.mp4"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let bundle = try #require(WallpaperBundle(from: dir))
        #expect(bundle.type == .video)
    }

    @Test func typeIsImageForPng() throws {
        let dir = try makeBundle(binaryFiles: ["scene.png"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let bundle = try #require(WallpaperBundle(from: dir))
        #expect(bundle.type == .image)
    }

    @Test func typeFromLivelyInfoOverridesFileDetection() throws {
        // LivelyInfo says "video" but there's only a png — livelyInfo.type wins when
        // there is no FileName and no matching extension files.
        let dir = try makeBundle(binaryFiles: ["art.png"], livelyInfo: ["Type": "video"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let bundle = try #require(WallpaperBundle(from: dir))
        #expect(bundle.type == .video)
    }

    // MARK: FileName field

    @Test func fileNameOverridesDefaultIndexEntry() throws {
        let dir = try makeBundle(
            files: ["custom.html": "<html/>", "index.html": "<html/>"],
            livelyInfo: ["Type": "web", "FileName": "custom.html"]
        )
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let bundle = try #require(WallpaperBundle(from: dir))
        #expect(bundle.indexURL?.lastPathComponent == "custom.html")
    }

    @Test func fileNameResolvesVideoEntry() throws {
        let dir = try makeBundle(
            binaryFiles: ["clip.mp4"],
            livelyInfo: ["Type": "video", "FileName": "clip.mp4"]
        )
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let bundle = try #require(WallpaperBundle(from: dir))
        #expect(bundle.videoURL?.lastPathComponent == "clip.mp4")
    }

    // MARK: Path traversal prevention

    @Test func rejectsPathTraversalInFileName() throws {
        let dir = try makeBundle(
            files: ["index.html": ""],
            livelyInfo: ["Type": "web", "FileName": "../escape.html"]
        )
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let bundle = try #require(WallpaperBundle(from: dir))
        // Falls back to index.html — the traversal attempt is silently discarded
        #expect(bundle.indexURL?.lastPathComponent == "index.html")
    }

    @Test func rejectsAbsolutePathInFileName() throws {
        let dir = try makeBundle(
            files: ["index.html": ""],
            livelyInfo: ["Type": "web", "FileName": "/etc/passwd"]
        )
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let bundle = try #require(WallpaperBundle(from: dir))
        #expect(bundle.indexURL?.lastPathComponent == "index.html")
    }

    @Test func rejectsWindowsStyleAbsolutePathInFileName() throws {
        let dir = try makeBundle(
            files: ["index.html": ""],
            livelyInfo: ["Type": "web", "FileName": "C:\\Windows\\System32\\cmd.exe"]
        )
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let bundle = try #require(WallpaperBundle(from: dir))
        #expect(bundle.indexURL?.lastPathComponent == "index.html")
    }

    // MARK: Name resolution

    @Test func nameFromLivelyInfoTitle() throws {
        let dir = try makeBundle(
            files: ["index.html": ""],
            livelyInfo: ["Title": "Beautiful Rain"]
        )
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let bundle = try #require(WallpaperBundle(from: dir))
        #expect(bundle.name == "Beautiful Rain")
    }

    @Test func nameFromFolderWhenNoTitle() throws {
        let dir = try makeBundle(name: "MyWallpaper", files: ["index.html": ""])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let bundle = try #require(WallpaperBundle(from: dir))
        #expect(bundle.name == "MyWallpaper")
    }

    // MARK: Preview / image exclusion

    @Test func imageURLExcludesPreviewFiles() throws {
        let dir = try makeBundle(binaryFiles: ["preview.png", "scene.png"])
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let bundle = try #require(WallpaperBundle(from: dir))
        #expect(bundle.imageURL?.lastPathComponent == "scene.png")
    }

    // MARK: Init guard

    @Test func initFailsForNonExistentPath() {
        let missing = URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID().uuidString)")
        #expect(WallpaperBundle(from: missing) == nil)
    }

    @Test func initFailsForFile_notDirectory() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("AetherDeskTests-\(UUID().uuidString).html")
        try "<html/>".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(WallpaperBundle(from: file) == nil)
    }
}
