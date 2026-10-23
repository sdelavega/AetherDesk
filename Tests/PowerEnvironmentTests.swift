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
import WebKit

@Suite("Power environment")
struct PowerEnvironmentTests {
    @MainActor @Test
    func reinjectsPowerEnvironmentWithoutChangingFPSCap() async throws {
        let webView = WKWebView()
        webView.loadHTMLString("<html><body>Power environment</body></html>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await webView.evaluateJavaScript("document.body && document.body.textContent")) as? String == "Power environment" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await webView.evaluateJavaScript("""
        window.updates = 0;
        window.aetherDesk = {system: {}, _setEnvironment: function(env) {
            Object.assign(this.system, env.system); window.updates++;
        }};
        Object.defineProperty(window.aetherDesk.system, 'fpsCap', {value: 30, writable: false, enumerable: true});
        """)
        let bridge = PropertyBridge(displayID: 0)
        bridge.setWebView(webView)
        for count in 1...2 {
            bridge.injectEnvironment()
            let result = try await webView.evaluateJavaScript("({system: aetherDesk.system, updates: window.updates})") as? [String: Any]
            let system = result?["system"] as? [String: Any]
            #expect(result?["updates"] as? Int == count)
            #expect(system?["onBattery"] as? Bool == WallpaperManager.isOnBatteryPower)
            #expect(system?["qualityMode"] as? String == PropertyBridge.qualityMode(
                onBattery: WallpaperManager.isOnBatteryPower, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled))
            #expect(system?["fpsCap"] as? Int == 30)
        }
        webView.stopLoading()
        bridge.setWebView(nil)
    }

    @Test(arguments: [false, true])
    func qualityMapping(onBattery: Bool) {
        #expect(PropertyBridge.qualityMode(onBattery: onBattery, lowPower: false) == (onBattery ? "eco" : "balanced"))
        #expect(PropertyBridge.qualityMode(onBattery: onBattery, lowPower: true) == "eco")
    }
}
