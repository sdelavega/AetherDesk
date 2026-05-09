// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega. All rights reserved.
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

@Suite("WallpaperValidator") struct WallpaperValidatorTests {
    let validator = WallpaperValidator()

    private func makeBundle(js: String, livelyInfo: [String: Any]? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ValidatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try js.write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        if let info = livelyInfo {
            let data = try JSONSerialization.data(withJSONObject: info)
            try data.write(to: dir.appendingPathComponent("LivelyInfo.json"))
        }
        return dir
    }

    private func assertRejected(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        let c = validator.validate(at: url)
        guard case .rejected = c else {
            Issue.record("Expected .rejected, got \(c)")
            return
        }
    }

    private func assertAllowed(_ url: URL) {
        let c = validator.validate(at: url)
        guard case .allowed = c else {
            Issue.record("Expected .allowed, got \(c)")
            return
        }
    }

    // MARK: Clean bundle

    @Test func allowsCleanBundle() throws {
        let dir = try makeBundle(js: "requestAnimationFrame(draw);")
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = validator.report(at: dir)
        assertAllowed(dir)
        #expect(report.warnings.isEmpty)
        #expect(report.issues.isEmpty)
    }

    @Test func reportRecordsBundleSize() throws {
        let content = String(repeating: "x", count: 2000)
        let dir = try makeBundle(js: content)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = validator.report(at: dir)
        #expect(report.totalBundleBytes >= 2000)
        #expect(report.indexJSLength == 2000)
    }

    // MARK: Hard rejects — tracker domains

    @Test func rejectsGoogleTagManager() throws {
        let dir = try makeBundle(js: "googletagmanager.com/gtm.js")
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    @Test func rejectsGoogleAnalytics() throws {
        let dir = try makeBundle(js: "google-analytics.com/ga.js")
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    @Test func rejectsDoubleclick() throws {
        let dir = try makeBundle(js: "doubleclick.net/pixel")
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    @Test func rejectsFacebookNet() throws {
        let dir = try makeBundle(js: "facebook.net/en_US/fbevents.js")
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    // MARK: Hard rejects — crypto miners

    @Test func rejectsCoinHive() throws {
        let dir = try makeBundle(js: "coinhive.min.js")
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    @Test func rejectsCryptoNight() throws {
        let dir = try makeBundle(js: "cryptonight(data)")
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    @Test func rejectsStratumTCP() throws {
        let dir = try makeBundle(js: "stratum+tcp://pool.example.com")
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    // MARK: Hard rejects — dangerous JS

    @Test func rejectsWhileTrue() throws {
        let dir = try makeBundle(js: "while(true){}")
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    @Test func rejectsWhileTrueWithSpaces() throws {
        let dir = try makeBundle(js: "while (true) {}")
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    @Test func rejectsServiceWorker() throws {
        let dir = try makeBundle(js: "navigator.serviceWorker.register('sw.js')")
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    @Test func rejectsSharedWorker() throws {
        let dir = try makeBundle(js: "new SharedWorker('worker.js')")
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    @Test func rejectsWindowOpen() throws {
        let dir = try makeBundle(js: "window.open('https://example.com')")
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    @Test func rejectsExcessiveNetworkCalls() throws {
        let js = (0..<11).map { _ in "fetch('/api');" }.joined()
        let dir = try makeBundle(js: js)
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    // MARK: Hard rejects — LivelyInfo type

    @Test func rejectsApplicationType() throws {
        let dir = try makeBundle(js: "", livelyInfo: ["Type": "application"])
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    @Test func rejectsUnityType() throws {
        let dir = try makeBundle(js: "", livelyInfo: ["Type": "unity"])
        defer { try? FileManager.default.removeItem(at: dir) }
        assertRejected(dir)
    }

    // MARK: Warnings (allowedWithLimits)

    @Test func warnsShadowBlur() throws {
        let js = (0..<6).map { _ in "ctx.shadowBlur=5;" }.joined()
        let dir = try makeBundle(js: js)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = validator.report(at: dir)
        #expect(report.warnings.contains { $0.contains("shadowBlur") })
        if case .allowedWithLimits = report.classification { } else {
            Issue.record("Expected .allowedWithLimits for heavy shadowBlur")
        }
    }

    @Test func warnsWebGLSingleQuote() throws {
        let dir = try makeBundle(js: "canvas.getContext('webgl')")
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = validator.report(at: dir)
        #expect(report.warnings.contains { $0.contains("WebGL") })
    }

    @Test func warnsWebGLDoubleQuote() throws {
        let dir = try makeBundle(js: #"canvas.getContext("webgl")"#)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = validator.report(at: dir)
        #expect(report.warnings.contains { $0.contains("WebGL") })
    }

    @Test func warnsFetch() throws {
        let dir = try makeBundle(js: "fetch('/api')")
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = validator.report(at: dir)
        #expect(report.warnings.contains { $0.contains("network") || $0.contains("rate-limited") })
    }

    @Test func warnsDocumentWrite() throws {
        let dir = try makeBundle(js: "document.write('hello')")
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = validator.report(at: dir)
        #expect(report.warnings.contains { $0.contains("document.write(") })
    }

    @Test func warnsEval() throws {
        let dir = try makeBundle(js: "eval(userInput)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = validator.report(at: dir)
        #expect(report.warnings.contains { $0.contains("eval(") })
    }

    @Test func warnsGeolocation() throws {
        let dir = try makeBundle(js: "navigator.geolocation.getCurrentPosition(cb)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = validator.report(at: dir)
        #expect(report.warnings.contains { $0.contains("geolocation") })
    }

    @Test func warnsHeavyCompositeBlending() throws {
        let js = (0..<6).map { _ in "ctx.globalCompositeOperation='screen';" }.joined()
        let dir = try makeBundle(js: js)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = validator.report(at: dir)
        #expect(report.warnings.contains { $0.contains("composite") })
    }
}
