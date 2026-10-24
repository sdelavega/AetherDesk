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

/// One automatic wake retry per display, until the user selects a wallpaper.
struct SafeModeRetryPolicy {
    private var demoted: Set<DisplayIdentity> = []
    private var retried: Set<DisplayIdentity> = []

    mutating func shouldRetry(_ identity: DisplayIdentity) -> Bool {
        guard demoted.contains(identity) else { return false }
        return retried.insert(identity).inserted
    }

    mutating func recordDemotion(_ identity: DisplayIdentity) {
        demoted.insert(identity)
    }

    mutating func reset(_ identity: DisplayIdentity) {
        demoted.remove(identity)
        retried.remove(identity)
    }
}
