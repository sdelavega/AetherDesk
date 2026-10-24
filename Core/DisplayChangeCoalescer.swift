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

protocol Cancellable {
    func cancel()
}

extension DispatchWorkItem: Cancellable {}

/// Trailing-edge debounce; callers and the scheduler use the same queue.
final class DisplayChangeCoalescer {
    private let delay: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Cancellable
    private var pending: Cancellable?
    private var generation: UInt64 = 0
    var onFire: (() -> Void)?

    init(delay: TimeInterval = 0.25,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Cancellable) {
        self.delay = delay
        self.schedule = schedule
    }

    deinit { pending?.cancel() }

    func signal() {
        pending?.cancel()
        generation &+= 1
        let expectedGeneration = generation
        pending = schedule(delay) { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.pending = nil
            self.onFire?()
        }
    }
}
