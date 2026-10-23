// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega
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
import Testing

@Suite struct WallpaperImporterTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cleanup(_ root: URL) {
        let subject = importer(in: root)
        for bundle in subject.listImportedWallpapers() {
            RuntimePolicyStore.shared.delete(for: bundle.id)
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func importer(in root: URL) -> WallpaperImporter {
        WallpaperImporter(fileManager: .default,
                          wallpapersDirectory: root.appendingPathComponent("library"),
                          bundledWallpapersDirectory: root.appendingPathComponent("bundled"))
    }

    private func expectInside(_ resource: URL?, bundle: WallpaperBundle) {
        if let resource {
            #expect(resource.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
                bundle.baseURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"))
        }
    }

    private func expectEmpty(_ importer: WallpaperImporter) throws {
        #expect(try FileManager.default.contentsOfDirectory(
            at: importer.wallpapersDirectory, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func customFilename() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let subject = importer(in: root)
        let bundle = try subject.importWallpaper(from: Fixtures.url("web-custom-filename")).bundle
        #expect(bundle.type == .web)
        #expect(bundle.indexURL?.lastPathComponent == "main.html")
        #expect(try String(contentsOf: #require(bundle.indexURL), encoding: .utf8)
            == String(contentsOf: Fixtures.url("web-custom-filename").appendingPathComponent("main.html"), encoding: .utf8))
        expectInside(bundle.indexURL, bundle: bundle)
        #expect(subject.listImportedWallpapers().count == 1)
        #expect(subject.listBundledWallpapers().isEmpty)
    }

    @Test func zipAndLivelyImportIdentically() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let subject = importer(in: root)
        let zip = try Fixtures.archive("web-custom-filename", as: "zip")
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        let lively = try Fixtures.archive("web-custom-filename", as: "lively")
        defer { try? FileManager.default.removeItem(at: lively.deletingLastPathComponent()) }
        let first = try subject.importWallpaper(from: zip).bundle
        let second = try subject.importWallpaper(from: lively).bundle
        #expect(first.name == second.name)
        #expect(first.type == second.type)
        #expect(first.indexURL?.lastPathComponent == "main.html")
        #expect(second.indexURL?.lastPathComponent == "main.html")
        #expect(try Data(contentsOf: #require(first.indexURL)) == Data(contentsOf: #require(second.indexURL)))
        expectInside(first.indexURL, bundle: first)
        expectInside(second.indexURL, bundle: second)
    }

    @Test(arguments: ["video", "image"])
    func mediaFixtures(name: String) throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let bundle = try importer(in: root).importWallpaper(from: Fixtures.url(name)).bundle
        let resource = try #require(name == "video" ? bundle.videoURL : bundle.imageURL)
        #expect(bundle.type == (name == "video" ? .video : .image))
        #expect(try Data(contentsOf: resource).count <= (name == "video" ? 50_000 : 10_000))
        expectInside(resource, bundle: bundle)
    }

    @Test(arguments: ["traversal-filename", "traversal-preview"])
    func traversalStaysInside(name: String) throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let subject = importer(in: root)
        let outside = root.appendingPathComponent("etc", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside bundle".utf8).write(to: outside.appendingPathComponent("hosts"))
        try FileManager.default.copyItem(at: Fixtures.url("image").appendingPathComponent("sample.png"),
                                        to: subject.wallpapersDirectory.appendingPathComponent("secret.png"))
        do {
            let bundle = try subject.importWallpaper(from: Fixtures.url(name)).bundle
            let index = try #require(bundle.indexURL)
            #expect(index.lastPathComponent == "index.html")
            expectInside(index, bundle: bundle)
            expectInside(bundle.videoURL, bundle: bundle)
            expectInside(bundle.imageURL, bundle: bundle)
            expectInside(bundle.previewImageURL, bundle: bundle)
        } catch is ImportError {
            #expect(subject.listImportedWallpapers().isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func symlinkEscapeIsRejected(archived: Bool) throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let copy = root.appendingPathComponent("source")
        try FileManager.default.copyItem(at: Fixtures.url("web-custom-filename"), to: copy)
        try FileManager.default.createSymbolicLink(atPath: copy.appendingPathComponent("escape").path,
                                                  withDestinationPath: "/etc")
        let archive = archived ? try Fixtures.archiveDirectory(copy, as: "zip") : nil
        defer {
            if let archive { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        }
        let subject = importer(in: root)
        do {
            _ = try subject.importWallpaper(from: archive ?? copy)
            Issue.record("Expected symlink escape rejection")
        } catch ImportError.rejected(let reason) {
            #expect(reason == "Bundle contains a symlink or path outside its root")
        }
        try expectEmpty(subject)
    }

    @Test func zipBombIsRejected() throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.copyItem(at: Fixtures.url("web-custom-filename"), to: source)
        let zeros = source.appendingPathComponent("zeros.bin")
        #expect(FileManager.default.createFile(atPath: zeros.path, contents: nil))
        let handle = try FileHandle(forWritingTo: zeros)
        do {
            let chunk = Data(repeating: 0, count: 1_000_000)
            for _ in 0..<200 { try handle.write(contentsOf: chunk) }
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let archive = try Fixtures.archiveDirectory(source, as: "zip")
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let subject = importer(in: root)
        do {
            _ = try subject.importWallpaper(from: archive)
            Issue.record("Expected expanded archive size rejection")
        } catch ImportError.archiveExtractionFailed(let underlying) {
            let error = underlying as NSError
            #expect(error.domain == "ÆtherDesk.Import")
            #expect(error.code == 2)
            #expect(error.localizedDescription == "Extracted content exceeds maximum bundle size")
        }
        try expectEmpty(subject)
    }

    @Test(arguments: [false, true])
    func malformedJSONIsRejected(archived: Bool) throws {
        let root = try temporaryDirectory()
        defer { cleanup(root) }
        let archive = archived ? try Fixtures.archive("malformed-json", as: "lively") : nil
        defer {
            if let archive { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        }
        let subject = importer(in: root)
        do {
            _ = try subject.importWallpaper(from: archive ?? Fixtures.url("malformed-json"))
            Issue.record("Expected malformed JSON parse rejection")
        } catch ImportError.rejected(let reason) {
            #expect(reason == "Could not parse LivelyInfo.json")
        }
        try expectEmpty(subject)
    }
}
