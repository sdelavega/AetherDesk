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

// Compile the production types so the probe measures the app's actual keys.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("display-probe-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let main = temporary.appendingPathComponent("main.swift")
try #"""
import CoreGraphics
import Foundation

func activeDisplays() throws -> [DisplayHardwareInfo] {
    var count: UInt32 = 0
    var result = CGGetActiveDisplayList(0, nil, &count)
    guard result == .success else { throw NSError(domain: "CGError", code: Int(result.rawValue)) }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    result = CGGetActiveDisplayList(count, &ids, &count)
    guard result == .success else { throw NSError(domain: "CGError", code: Int(result.rawValue)) }
    return ids.prefix(Int(count)).map { DisplayHardwareInfo.live($0, frame: CGDisplayBounds($0)) }
}

let displays = try activeDisplays()
if displays.isEmpty { print("No active displays.") }
for display in displays {
    print("ID: \(display.displayID)")
    print("UUID: \(display.uuid ?? "nil")")
    print("vendor: \(display.vendor), model: \(display.model), serial: \(display.serial)")
    print("frame: \(display.frame)")
    print("primary: \(DisplayIdentity.primary(for: display, among: displays).key)")
}
"""#.write(to: main, atomically: true, encoding: .utf8)

func run(_ arguments: [String]) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

let executable = temporary.appendingPathComponent("display-probe")
let compileStatus = try run([
    "swiftc", root.appendingPathComponent("Core/DisplayHardwareInfo.swift").path,
    root.appendingPathComponent("Core/DisplayIdentity.swift").path, main.path,
    "-o", executable.path
])
guard compileStatus == 0 else {
    try? FileManager.default.removeItem(at: temporary)
    exit(compileStatus)
}
let probe = Process()
probe.executableURL = executable
try probe.run()
probe.waitUntilExit()
let status = probe.terminationStatus
try? FileManager.default.removeItem(at: temporary)
exit(status)
