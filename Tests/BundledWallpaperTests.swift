import Testing
import Foundation

/// Regression suite that validates every bundled sample wallpaper against the
/// same rules the importer uses. These tests should stay green in perpetuity;
/// a failure here means a bundled wallpaper was broken or a parser/validator
/// regressed.
@Suite("Bundled wallpapers") struct BundledWallpaperTests {

    private func wallpapersDir() -> URL {
        // Tests/ is one level below the repo root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Resources/Wallpapers")
    }

    private func bundleDirs() throws -> [URL] {
        let dir = wallpapersDir()
        guard FileManager.default.fileExists(atPath: dir.path) else {
            Issue.record("Wallpapers directory not found at \(dir.path)")
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    @Test func allBundlesInitialise() throws {
        let dirs = try bundleDirs()
        #expect(!dirs.isEmpty)
        for dir in dirs {
            let bundle = try #require(
                WallpaperBundle(from: dir),
                "WallpaperBundle(from:) returned nil for \(dir.lastPathComponent)"
            )
            #expect(bundle.type != .unknown,
                    "\(dir.lastPathComponent) resolved to .unknown type")
        }
    }

    @Test func allBundlesHaveLivelyInfo() throws {
        for dir in try bundleDirs() {
            let info = try #require(
                LivelyInfoParser().parse(from: dir),
                "Missing or invalid LivelyInfo.json in \(dir.lastPathComponent)"
            )
            #expect(info.Title != nil,
                    "\(dir.lastPathComponent) LivelyInfo.json has no Title")
        }
    }

    @Test func allBundlesPassValidation() throws {
        let validator = WallpaperValidator()
        for dir in try bundleDirs() {
            let report = validator.report(at: dir)
            if case .rejected(let reason) = report.classification {
                Issue.record("\(dir.lastPathComponent) rejected by validator: \(reason)")
            }
        }
    }

    @Test func allBundlesHaveStableIDs() throws {
        for dir in try bundleDirs() {
            guard let b1 = WallpaperBundle(from: dir),
                  let b2 = WallpaperBundle(from: dir) else { continue }
            #expect(b1.id == b2.id,
                    "\(dir.lastPathComponent) produced different IDs across two initialisations")
        }
    }

    @Test func allWebBundlesHaveResolvableIndexURL() throws {
        for dir in try bundleDirs() {
            guard let bundle = WallpaperBundle(from: dir), bundle.type == .web else { continue }
            let url = try #require(
                bundle.indexURL,
                "\(bundle.name) (.web) has no resolvable indexURL"
            )
            #expect(FileManager.default.fileExists(atPath: url.path),
                    "\(bundle.name) indexURL points to missing file: \(url.path)")
        }
    }
}
