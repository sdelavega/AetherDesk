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

@Suite struct DisplayChangeCoalescerTests {
    @Test func burstFiresOnceAfterLastSignal() {
        let scheduler = ManualDisplayScheduler()
        let coalescer = DisplayChangeCoalescer(schedule: scheduler.schedule)
        var fires: [TimeInterval] = []
        coalescer.onFire = { fires.append(scheduler.now) }

        for time in [0.0, 0.05, 0.10, 0.15, 0.20] {
            scheduler.advance(to: time)
            coalescer.signal()
        }
        scheduler.advance(to: 0.449)
        #expect(fires.isEmpty)
        scheduler.advance(to: 0.45)
        #expect(fires == [0.45])
        scheduler.advance(to: 1.0)
        #expect(fires == [0.45])

        coalescer.signal()
        scheduler.advance(to: 1.25)
        #expect(fires == [0.45, 1.25])
    }

    @Test func deinitCancelsPendingFire() {
        let scheduler = ManualDisplayScheduler()
        var fires = 0
        var coalescer: DisplayChangeCoalescer? = DisplayChangeCoalescer(schedule: scheduler.schedule)
        coalescer?.onFire = { fires += 1 }
        coalescer?.signal()
        coalescer = nil
        scheduler.advance(to: 1)
        #expect(fires == 0)
        #expect(scheduler.jobs.allSatisfy { $0.cancelled })
    }
}

private final class ManualDisplayScheduler {
    final class Job: Cancellable {
        let deadline: TimeInterval
        let action: () -> Void
        var cancelled = false
        init(deadline: TimeInterval, action: @escaping () -> Void) {
            self.deadline = deadline
            self.action = action
        }
        func cancel() { cancelled = true }
    }

    private(set) var now: TimeInterval = 0
    private(set) var jobs: [Job] = []

    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> Cancellable {
        let job = Job(deadline: now + delay, action: action)
        jobs.append(job)
        return job
    }

    func advance(to time: TimeInterval) {
        while let index = jobs.indices.filter({ jobs[$0].deadline <= time && !jobs[$0].cancelled })
            .min(by: { jobs[$0].deadline < jobs[$1].deadline }) {
            let job = jobs.remove(at: index)
            now = job.deadline
            job.action()
        }
        now = time
    }
}
