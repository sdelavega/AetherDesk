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
import Foundation

/// A single wallpaper instance attached to a single display. Each display
/// may own at most one WallpaperRuntime at a time.
///
/// Lifecycle:
///   init → start() → [pause() / resume() / updateProperty()] → stop()
///
/// Implementations must:
///   - never steal focus
///   - never call AppKit on non-main threads
///   - be resilient to `stop()` being called before `start()` succeeded
///   - degrade gracefully under pause / low-power mode
protocol WallpaperRuntime: AnyObject {
    var displayID: CGDirectDisplayID { get }
    var isPaused: Bool { get }
    var contentView: NSView { get }

    func start() throws
    func pause()
    func resume()
    func stop()
    func reload() throws
    func updateProperty(_ key: String, value: Any)
}

/// Errors produced by wallpaper runtimes during lifecycle operations.
/// The host uses these to decide whether to substitute a fallback / safe-mode
/// wallpaper or to surface an import report entry.
enum WallpaperRuntimeError: Error, CustomStringConvertible {
    case failedToLoad(String)
    case invalidBundle
    case contentNotFound
    case renderingFailed
    case timeout

    var description: String {
        switch self {
        case .failedToLoad(let s): return "Failed to load wallpaper: \(s)"
        case .invalidBundle:       return "Invalid wallpaper bundle"
        case .contentNotFound:     return "Wallpaper content not found"
        case .renderingFailed:     return "Wallpaper rendering failed"
        case .timeout:             return "Wallpaper timed out"
        }
    }
}
