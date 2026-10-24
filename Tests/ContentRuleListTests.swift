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

import Testing
import Foundation
import WebKit

/// WKContentRuleListStore rejects whole lists for unsupported regex syntax
/// (e.g. disjunctions), and ContentRuleListManager treats that as non-fatal,
/// so a broken list silently ships with its protection off. Compile each list
/// into a fresh store — never the default one, whose cache would hide a
/// regression behind a previously compiled list.
@Suite("ContentRuleList") struct ContentRuleListTests {

    @Test(arguments: [
        ("content blocklist", ContentRuleListManager.blocklistJSON),
        ("external network", ContentRuleListManager.externalNetworkBlockJSON),
        ("raw-IP WebSocket", ContentRuleListManager.rawIPWebSocketBlockJSON),
        ("SSRF subresource", ContentRuleListManager.ssrfBlockJSON),
    ])
    @MainActor
    func ruleListCompiles(label: String, json: String) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AetherDeskTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try #require(WKContentRuleListStore(url: dir))

        let error: Error? = await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: "test", encodedContentRuleList: json) { _, error in
                continuation.resume(returning: error)
            }
        }
        #expect(error == nil, "\(label) failed to compile: \(String(describing: error))")
    }
}
