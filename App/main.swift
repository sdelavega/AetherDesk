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

import AppKit
import os.log
import Foundation

// MARK: - Updater mode
// If launched with --aetherdesk-updater <pid> <oldAppPath> <newAppPath> <tempDir>,
// perform the atomic swap and relaunch without ever starting NSApplication.
//
// Excluded entirely from App Store builds: Apple Guideline 2.4.5(vii)
// prohibits an app from updating itself outside the Mac App Store, and this
// is the literal mechanism that does the self-replacing swap-and-relaunch.
// It must not exist as compiled code in the App Store binary, not merely be
// unreachable from the UI — so this is a compile-time exclusion, not a
// runtime guard.
#if !AETHERDESK_STORE
if CommandLine.arguments.count == 6,
   CommandLine.arguments[1] == "--aetherdesk-updater",
   let pid = Int32(CommandLine.arguments[2]) {
    let oldAppPath = CommandLine.arguments[3]
    let newAppPath = CommandLine.arguments[4]
    let tempDir    = CommandLine.arguments[5]
    let fm = FileManager.default

    // Wait for the parent process to die.
    while kill(pid, 0) == 0 {
        Thread.sleep(forTimeInterval: 0.5)
    }
    Thread.sleep(forTimeInterval: 1.0)

    do {
        if fm.fileExists(atPath: oldAppPath) {
            try fm.removeItem(atPath: oldAppPath)
        }
        try fm.moveItem(atPath: newAppPath, toPath: oldAppPath)
    } catch {
        FileHandle.standardError.write(Data("AetherDesk updater failed to swap: \(error.localizedDescription)\n".utf8))
        exit(1)
    }

    do {
        if fm.fileExists(atPath: tempDir) {
            try fm.removeItem(atPath: tempDir)
        }
    } catch {
        // Non-fatal: the swap succeeded.
        Logger.app.error("AetherDesk updater: cleanup warning: \(error.localizedDescription)")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [oldAppPath]
    do {
        try process.run()
    } catch {
        FileHandle.standardError.write(Data("AetherDesk updater failed to relaunch: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    exit(0)
}
#endif

// MARK: - Normal launch

// Single-instance guard: exit immediately if another copy is already running.
let dominated = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
if dominated.count > 1 {
    Logger.app.info("ÆtherDesk: another instance is already running — exiting.")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
