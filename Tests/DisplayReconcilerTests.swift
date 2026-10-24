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
import Testing

@Suite struct DisplayReconcilerTests {
    private let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    private func snapshot(_ id: CGDirectDisplayID, _ key: String,
                          frame: CGRect? = nil) -> DisplaySnapshot {
        DisplaySnapshot(info: DisplayHardwareInfo(displayID: id, uuid: key,
                                                   vendor: 1, model: 1, serial: 0,
                                                   frame: frame ?? self.frame),
                        identity: DisplayIdentity(key: key))
    }

    @Test func noChange() {
        let displays = [snapshot(2, "right"), snapshot(1, "left")]
        #expect(DisplayReconciler.reconcile(previous: displays, current: displays,
                                            sessionBundles: [:]) == [])
        #expect(DisplayReconciler.reconcile(previous: [], current: [], sessionBundles: [:]) == [])
    }

    @Test func unplugOneOfTwo() {
        let left = snapshot(1, "left")
        #expect(DisplayReconciler.reconcile(previous: [left, snapshot(2, "right")],
                                            current: [left], sessionBundles: [:]) == [.tearDownHost(2)])
    }

    @Test func replugSameIdentityWithNewID() {
        let bundle = UUID()
        let display = snapshot(9, "monitor")
        #expect(DisplayReconciler.reconcile(previous: [], current: [display],
                                            sessionBundles: [display.identity: bundle]) == [
            .createHost(9, frame: frame), .restore(9, .session(bundle))
        ])
        #expect(DisplayReconciler.reconcile(previous: [snapshot(1, "monitor")], current: [display],
                                            sessionBundles: [display.identity: bundle]) == [
            .tearDownHost(1), .createHost(9, frame: frame), .restore(9, .session(bundle))
        ])
    }

    @Test func newDisplayUsesPersistence() {
        #expect(DisplayReconciler.reconcile(previous: [], current: [snapshot(3, "new")],
                                            sessionBundles: [DisplayIdentity(key: "other"): UUID()]) == [
            .createHost(3, frame: frame), .restore(3, .persisted)
        ])
    }

    @Test func resolutionChangeOnlyReframes() {
        let resized = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        #expect(DisplayReconciler.reconcile(previous: [snapshot(1, "monitor")],
                                            current: [snapshot(1, "monitor", frame: resized)],
                                            sessionBundles: [:]) == [.reframeHost(1, frame: resized)])
    }

    @Test func positionAndSubpixelChangeReframeExactly() {
        let moved = CGRect(x: -1920, y: -0.25, width: 1920, height: 1080)
        #expect(DisplayReconciler.reconcile(previous: [snapshot(1, "monitor")],
                                            current: [snapshot(1, "monitor", frame: moved)],
                                            sessionBundles: [:]) == [.reframeHost(1, frame: moved)])
    }

    @Test func reusedIDRecreatesHost() {
        #expect(DisplayReconciler.reconcile(previous: [snapshot(1, "old")],
                                            current: [snapshot(1, "new")], sessionBundles: [:]) == [
            .tearDownHost(1), .createHost(1, frame: frame), .restore(1, .persisted)
        ])
    }

    @Test func twinsSwappedRestoreBundlesFollowingFrames() {
        let rightFrame = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        func twins(_ leftID: CGDirectDisplayID, _ rightID: CGDirectDisplayID) -> [DisplaySnapshot] {
            let infos = [DisplayHardwareInfo(displayID: leftID, uuid: nil, vendor: 1, model: 2,
                                             serial: 0, frame: frame),
                         DisplayHardwareInfo(displayID: rightID, uuid: nil, vendor: 1, model: 2,
                                             serial: 0, frame: rightFrame)]
            return infos.map { DisplaySnapshot(info: $0, identity: .primary(for: $0, among: infos)) }
        }
        let previous = twins(1, 2)
        let current = twins(2, 1)
        let leftBundle = UUID()
        let rightBundle = UUID()
        #expect(DisplayReconciler.reconcile(previous: previous, current: current,
                                            sessionBundles: [previous[0].identity: leftBundle,
                                                             previous[1].identity: rightBundle]) == [
            .tearDownHost(1), .tearDownHost(2),
            .createHost(1, frame: rightFrame), .restore(1, .session(rightBundle)),
            .createHost(2, frame: frame), .restore(2, .session(leftBundle))
        ])
    }

    @Test func actionGroupsAndIDsAreOrderedRegardlessOfInputOrder() {
        let moved = CGRect(x: -1920, y: 50, width: 1920, height: 1080)
        let previous = [snapshot(8, "gone8"), snapshot(6, "kept6"),
                        snapshot(7, "gone7"), snapshot(3, "kept3")]
        let current = [snapshot(6, "kept6", frame: moved), snapshot(5, "new5"),
                       snapshot(3, "kept3", frame: moved), snapshot(2, "new2")]
        let expected: [DisplayAction] = [
            .tearDownHost(7), .tearDownHost(8),
            .createHost(2, frame: frame), .restore(2, .persisted),
            .createHost(5, frame: frame), .restore(5, .persisted),
            .reframeHost(3, frame: moved), .reframeHost(6, frame: moved)
        ]
        #expect(DisplayReconciler.reconcile(previous: previous, current: current,
                                            sessionBundles: [:]) == expected)
        #expect(DisplayReconciler.reconcile(previous: Array(previous.reversed()),
                                            current: Array(current.reversed()), sessionBundles: [:]) == expected)
    }
}
