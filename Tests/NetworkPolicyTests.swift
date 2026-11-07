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

import Foundation
import Testing

@Suite("NetworkPolicy") struct NetworkPolicyTests {

    private func policy(allowLAN: Bool) -> NetworkPolicy {
        NetworkPolicy(bundleID: UUID(), allowLANAccess: allowLAN)
    }

    private func isAllowed(_ result: Result<URL, NetworkPolicy.DenialReason>) -> Bool {
        if case .success = result { return true }
        return false
    }

    @Test func rejectsNonNetworkSchemes() {
        // URLSession would read file://localhost/… from disk; LAN access must
        // never turn the native fetch bridge into a local file reader.
        for allowLAN in [false, true] {
            let p = policy(allowLAN: allowLAN)
            #expect(!isAllowed(p.validate(url: URL(string: "file://localhost/etc/hosts")!)))
            #expect(!isAllowed(p.validate(url: URL(string: "ftp://example.com/x")!)))
            #expect(!isAllowed(p.validate(url: URL(string: "data:text/plain,hi")!)))
        }
    }

    @Test func allowsWebSchemesForPublicHosts() {
        let p = policy(allowLAN: false)
        for string in ["https://api.open-meteo.com/v1/forecast", "http://example.com/",
                       "wss://example.com/socket", "ws://example.com/socket"] {
            #expect(isAllowed(p.validate(url: URL(string: string)!)), "\(string)")
        }
    }

    @Test func privateRawIPFollowsLANSetting() {
        let url = URL(string: "http://192.168.1.10/status")!
        #expect(!isAllowed(policy(allowLAN: false).validate(url: url)))
        #expect(isAllowed(policy(allowLAN: true).validate(url: url)))
    }

    @Test func publicRawIPIsAlwaysRejected() {
        let url = URL(string: "https://8.8.8.8/")!
        #expect(!isAllowed(policy(allowLAN: false).validate(url: url)))
        #expect(!isAllowed(policy(allowLAN: true).validate(url: url)))
    }

    @Test func metadataEndpointIsAlwaysRejected() {
        let url = URL(string: "http://169.254.169.254/latest/meta-data")!
        #expect(!isAllowed(policy(allowLAN: false).validate(url: url)))
        #expect(!isAllowed(policy(allowLAN: true).validate(url: url)))
    }

    @Test func hostnameResolvingToLANFollowsLANSetting() {
        // localhost resolves to loopback without any network access.
        let url = URL(string: "http://localhost:8123/api")!
        #expect(!isAllowed(policy(allowLAN: false).validateResolvedAddresses(for: url)))
        #expect(isAllowed(policy(allowLAN: true).validateResolvedAddresses(for: url)))
    }
}
