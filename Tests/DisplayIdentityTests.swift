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

@Suite struct DisplayIdentityTests {
    private func info(_ id: CGDirectDisplayID, uuid: String? = nil,
                      vendor: UInt32 = 10, model: UInt32 = 20,
                      serial: UInt32 = 0, x: CGFloat = 0, y: CGFloat = 0) -> DisplayHardwareInfo {
        DisplayHardwareInfo(displayID: id, uuid: uuid, vendor: vendor, model: model,
                            serial: serial, frame: CGRect(x: x, y: y, width: 1920, height: 1080))
    }

    @Test func uuidAndSerialPreference() {
        let display = info(42, uuid: "TEST-UUID", serial: 30)
        #expect(DisplayIdentity.candidates(for: display, among: [display]).map(\.key) == [
            "uuid:TEST-UUID", "display:10:20:30", "display:10:20:ord:0", "cgdisplay:42", "42"
        ])
        #expect(DisplayIdentity.primary(for: display, among: [display]).key == "uuid:TEST-UUID")
    }

    @Test func twinsUseSpatialOrderRegardlessOfInputOrder() {
        let left = info(42)
        let right = info(43, x: 1920)
        for displays in [[left, right], [right, left]] {
            #expect(DisplayIdentity.primary(for: left, among: displays).key == "display:10:20:ord:0")
            #expect(DisplayIdentity.primary(for: right, among: displays).key == "display:10:20:ord:1")
        }
    }

    @Test func verticalOrderAndOtherModels() {
        let top = info(42, y: -1080)
        let bottom = info(43)
        let other = info(44, model: 21, x: -1920)
        #expect(DisplayIdentity.primary(for: bottom, among: [bottom, other, top]).key == "display:10:20:ord:1")
    }

    @Test func missingHardwareUsesOnlyLegacyKeys() {
        for uuid in [nil, "TEST-UUID"] as [String?] {
            let display = info(42, uuid: uuid, vendor: 0, model: 0, serial: 30)
            let expected = (uuid.map { ["uuid:\($0)"] } ?? []) + ["cgdisplay:42", "42"]
            #expect(DisplayIdentity.candidates(for: display, among: [display]).map(\.key) == expected)
        }
    }

    @Test func serialZeroRetainsAllLegacyKeys() {
        let display = info(42)
        #expect(DisplayIdentity.candidates(for: display, among: [display]).map(\.key) == [
            "display:10:20:ord:0", "display:10:20:cgd:42", "cgdisplay:42", "42"
        ])
    }
}
