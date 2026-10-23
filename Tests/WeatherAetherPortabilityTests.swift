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

private let portableWallpapers = ["WeatherAether"]

@Suite("WeatherAether portability") struct WeatherAetherPortabilityTests {
    private func wallpaperURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Wallpapers/\(name)")
    }

    private func matches(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private func remoteReferences(in directory: URL) throws -> [String] {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        let files = try #require(FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: nil))
        let remote = #"(?:https?:|//)"#
        let script = #"<script\b[^>]*\bsrc\s*=\s*["']?\s*"# + remote
        let imports = #"\bimport\s*(?:\(\s*|[^;\n]*?\bfrom\s*)?["']\s*"# + remote
        let styles = #"<link\b[^>]*\bhref\s*=\s*["']?\s*"# + remote
            + #"|@import\s*(?:url\(\s*)?["']?\s*"# + remote
            + #"|(?<!new\s)\burl\(\s*["']?\s*"# + remote
        var violations: [String] = []
        for case let file as URL in files {
            let relative = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                .dropFirst(directory.pathComponents.count).joined(separator: "/")
            let vendor = relative.hasPrefix("vendor/")
            let scan = relative == "index.html" || file.pathExtension == "css"
                || (file.pathExtension == "js" && (vendor || relative.hasPrefix("js/")))
            guard scan else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            let pattern = vendor ? script + "|" + imports : script + "|" + imports + "|" + styles
            violations += try matches(pattern, in: text).map { relative + ": " + $0 }
        }
        return violations.sorted()
    }

    @Test(arguments: portableWallpapers)
    func bundledWallpaperIsPortable(_ name: String) throws {
        let directory = wallpaperURL(name)
        let references = try remoteReferences(in: directory)
        #expect(references.isEmpty, "Remote references: \(references)")
        let html = try String(contentsOf: directory.appendingPathComponent("index.html"), encoding: .utf8)
        let attributes = try matches(#"\b(?:src|href)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#, in: html)
        for attribute in attributes {
            let value = String(attribute.dropFirst(try #require(attribute.firstIndex(of: "=")).utf16Offset(in: attribute) + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !value.isEmpty, !value.hasPrefix("#"), URLComponents(string: value)?.scheme == nil,
                  !value.hasPrefix("//") else { continue }
            let path = String(value.split(whereSeparator: { $0 == "?" || $0 == "#" }).first ?? "")
            let decoded = path.removingPercentEncoding ?? path
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(decoded).path),
                    "Missing local resource: \(value)")
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("vendor/THREE-LICENSE.txt").path))
        if case .rejected(let reason) = WallpaperValidator().validate(at: directory) {
            Issue.record("Wallpaper blocked: \(reason)")
        }
    }

    @Test(arguments: portableWallpapers)
    func rejectsRemoteScriptInTemporaryCopy(_ name: String) throws {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Portability-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: wallpaperURL(name), to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        #expect(try remoteReferences(in: copy).isEmpty)
        let index = copy.appendingPathComponent("index.html")
        let html = try String(contentsOf: index, encoding: .utf8)
        try (html + "\n<script src=\"https://cdn.example/x.js\"></script>\n")
            .write(to: index, atomically: true, encoding: .utf8)
        let references = try remoteReferences(in: copy)
        #expect(references == ["index.html: <script src=\"https:"], "Remote references: \(references)")
    }
}
