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

enum Fixtures {
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    /// The caller owns the returned archive's temporary parent directory.
    static func archive(_ name: String, as ext: String) throws -> URL {
        try archiveDirectory(url(name), as: ext)
    }

    static func archiveDirectory(_ directory: URL, as ext: String) throws -> URL {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            let zip = temporary.appendingPathComponent("fixture.zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", directory.path, zip.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "Fixtures", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "Could not archive fixture"])
            }
            let result = temporary.appendingPathComponent("fixture.\(ext)")
            if result != zip { try FileManager.default.moveItem(at: zip, to: result) }
            return result
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
