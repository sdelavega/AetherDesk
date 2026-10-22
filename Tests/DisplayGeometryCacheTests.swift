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
import Testing

@Suite struct DisplayGeometryCacheTests {
    @Test func updateRoundTripsGeometry() throws {
        let cache = DisplayGeometryCache()
        let frame = CGRect(x: -1920, y: 300, width: 1920, height: 1080)
        cache.update([42: (frame, 2, false), 7: (.zero, 1, true)])
        let geometry = try #require(cache.geometry(for: 42))
        #expect(geometry.frame == frame)
        #expect(geometry.scale == 2)
        #expect(!geometry.isPrimary)
        #expect(cache.geometry(for: 7)?.isPrimary == true)
        #expect(cache.geometry(for: 99) == nil)
    }

    @Test func invalidateEmptiesCache() {
        let cache = DisplayGeometryCache()
        cache.update([42: (.zero, 2, true)])
        cache.invalidate()
        #expect(cache.geometry(for: 42) == nil)
    }

    @Test func updateReplacesDisconnectedEntries() {
        let cache = DisplayGeometryCache()
        cache.update([42: (.zero, 2, true)])
        cache.update([7: (.zero, 1, true)])
        #expect(cache.geometry(for: 42) == nil)
        #expect(cache.geometry(for: 7)?.scale == 1)
    }
}
