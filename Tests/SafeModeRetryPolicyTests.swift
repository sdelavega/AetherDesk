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

import Testing

@Suite struct SafeModeRetryPolicyTests {
    private let display = DisplayIdentity(key: "uuid:display-a")
    private let other = DisplayIdentity(key: "uuid:display-b")

    @Test func firstWakeAfterDemotionRetries() {
        var policy = SafeModeRetryPolicy()
        policy.recordDemotion(display)
        let retry = policy.shouldRetry(display)
        #expect(retry)
    }

    @Test func laterWakesDoNotRetry() {
        var policy = SafeModeRetryPolicy()
        policy.recordDemotion(display)
        let first = policy.shouldRetry(display)
        let second = policy.shouldRetry(display)
        #expect(first)
        #expect(!second)
        // A failed retry demotes again, but must not grant another attempt.
        policy.recordDemotion(display)
        let afterFailure = policy.shouldRetry(display)
        #expect(!afterFailure)
    }

    @Test func userResetAllowsAnotherDemotionRetry() {
        var policy = SafeModeRetryPolicy()
        policy.recordDemotion(display)
        let first = policy.shouldRetry(display)
        #expect(first)
        policy.reset(display)
        let beforeDemotion = policy.shouldRetry(display)
        #expect(!beforeDemotion)
        policy.recordDemotion(display)
        let afterDemotion = policy.shouldRetry(display)
        #expect(afterDemotion)
    }

    @Test func neverDemotedDoesNotRetry() {
        var policy = SafeModeRetryPolicy()
        let retry = policy.shouldRetry(display)
        #expect(!retry)
    }

    @Test func displaysHaveIndependentRetryBudgets() {
        var policy = SafeModeRetryPolicy()
        policy.recordDemotion(display)
        policy.recordDemotion(other)
        let first = policy.shouldRetry(display)
        let second = policy.shouldRetry(other)
        #expect(first)
        #expect(second)
        policy.reset(display)
        policy.recordDemotion(display)
        let resetDisplay = policy.shouldRetry(display)
        let unchangedDisplay = policy.shouldRetry(other)
        #expect(resetDisplay)
        #expect(!unchangedDisplay)
    }
}
