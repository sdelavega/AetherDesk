// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega.
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

// MARK: - Test host

// When hosting AetherDeskStoreTests, run a bare NSApplication: no
// single-instance exit (the user's own copy may be running), no wallpapers on
// the desktop, no reads or writes of the user's settings. XCTest injects the
// test bundle into this process and drives it.
if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
    exit(0)
}

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
