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
            let bundle = try #require(WallpaperBundle(from: dir))
            let report = validator.report(at: dir, bundle: bundle)
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
