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

import CoreGraphics
import Foundation

final class DisplayGeometryCache {
    static let shared = DisplayGeometryCache()

    private let lock = NSLock()
    private var entries: [CGDirectDisplayID: (frame: CGRect, scale: CGFloat, isPrimary: Bool)] = [:]

    func geometry(for id: CGDirectDisplayID) -> (frame: CGRect, scale: CGFloat, isPrimary: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]
    }

    func update(_ entries: [CGDirectDisplayID: (CGRect, CGFloat, Bool)]) {
        lock.lock()
        defer { lock.unlock() }
        self.entries = entries
    }

    func invalidate() {
        update([:])
    }
}
