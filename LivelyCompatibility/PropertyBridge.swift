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

import Foundation
import os.log
import AppKit
import WebKit

/// Pumps property updates from the native UI into a WKWebView-hosted
/// HTML wallpaper (and handles JS -> native read-backs).
///
/// Contract with the web runtime:
///   - `setWebView(_:)` must be called before `inject*` methods.
///   - `setInitialProperties(_:)` establishes the starting state.
///   - `injectProperties()` is called on navigation-did-finish so the
///     wallpaper sees properties before rendering begins.
///   - `updateProperty(_:value:)` pushes a single property update live
///     into the page (fires any registered `aetherDesk.properties.onUpdate`
///     callback on the JS side).
final class PropertyBridge: NSObject {

    private let displayID: CGDirectDisplayID
    private let fpsCap: Int
    private var properties: [String: Any] = [:]
    private weak var webView: WKWebView?

    // Debounce batching: accumulate property updates and flush in one JS eval.
    private var pendingUpdates: [String: Any] = [:]
    private var flushWorkItem: DispatchWorkItem?
    private static let debounceInterval: TimeInterval = 0.05

    init(displayID: CGDirectDisplayID,
         fpsCap: Int = Constants.Defaults.fpsCap) {
        self.displayID = displayID
        self.fpsCap = min(Constants.Defaults.maxFPS,
                          max(Constants.Defaults.minFPS, fpsCap))
        super.init()
    }

    // MARK: Setup

    func setWebView(_ webView: WKWebView?) {
        self.webView = webView
    }

    func setInitialProperties(_ livelyProperties: [LivelyProperty],
                              overrides: [String: Any] = [:]) {
        for prop in livelyProperties {
            properties[prop.name] = prop.value.value
        }
        properties.merge(overrides) { _, override in override }
    }

    func currentProperties() -> [String: Any] {
        properties
    }

    // MARK: Outbound (native -> JS)

    /// Push the full property dictionary into the page and fire the
    /// wallpaper's registered `onUpdate` callback.
    func injectProperties() {
        guard let webView = webView else { return }
        let json = jsonFragment(properties)
        let script = """
        (function() {
            if (window.aetherDesk && window.aetherDesk._notify) {
                window.aetherDesk._notify(\(json));
            } else {
                window._aetherDeskProperties = \(json);
            }
            if (typeof livelyPropertyListener === 'function') {
                var props = \(json);
                for (var k in props) { livelyPropertyListener(k, props[k]); }
            }
        })();
        """
        evaluate(script, on: webView, tag: "injectProperties")
    }

    /// Push a single property delta into the page (debounced).
    /// Skips dispatch if the value hasn't changed.
    func updateProperty(_ key: String, value: Any) {
        let existing = properties[key]
        if let existing = existing as? Double, let value = value as? Double, existing == value { return }
        if let existing = existing as? Int, let value = value as? Int, existing == value { return }
        if let existing = existing as? String, let value = value as? String, existing == value { return }
        if let existing = existing as? Bool, let value = value as? Bool, existing == value { return }
        properties[key] = value
        pendingUpdates[key] = value
        scheduleFlush()
    }

    /// Deliver any pending updates immediately. Call before stop/inject.
    func flushNow() {
        flushWorkItem?.cancel()
        flushWorkItem = nil
        flushPendingUpdates()
    }

    private func scheduleFlush() {
        flushWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingUpdates()
        }
        flushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    private func flushPendingUpdates() {
        guard !pendingUpdates.isEmpty, let webView = webView else {
            pendingUpdates.removeAll()
            return
        }

        let updates = pendingUpdates
        pendingUpdates.removeAll()

        let updatesJSON = jsonFragment(updates)
        let script = """
        (function() {
            window._aetherDeskProperties = window._aetherDeskProperties || {};
            var updates = \(updatesJSON);
            for (var k in updates) { window._aetherDeskProperties[k] = updates[k]; }
            if (window.aetherDesk && window.aetherDesk._notify) {
                window.aetherDesk._notify(window._aetherDeskProperties);
            }
            if (typeof livelyPropertyListener === 'function') {
                for (var k in updates) { livelyPropertyListener(k, updates[k]); }
            }
        })();
        """
        evaluate(script, on: webView, tag: "flushProperties(\(updates.count) keys)")
    }

    /// Push display/system environment info into the page. Called on
    /// `didFinish` navigation so the wallpaper sees correct display size
    /// even when rendered in an offscreen web view.
    func injectEnvironment() {
        guard let webView = webView else { return }

        let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let displayDict: [String: Any] = [
            "id":          Int(displayID),
            "width":       Int(screen?.frame.width ?? 1920),
            "height":      Int(screen?.frame.height ?? 1080),
            "scaleFactor": Double(screen?.backingScaleFactor ?? 2.0),
            "isPrimary":   CGDisplayIsMain(displayID) != 0
        ]
        let isLowPower: Bool
        if #available(macOS 12.0, *) {
            isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        } else {
            isLowPower = false
        }
        let systemDict: [String: Any] = [
            "isLowPowerMode": isLowPower,
            "isOnline":       true,
            "fpsCap":         fpsCap,
            "qualityMode":    "balanced"
        ]
        let env: [String: Any] = ["display": displayDict, "system": systemDict]
        let envJSON = jsonFragment(env)

        let script = """
        (function() {
            if (window.aetherDesk && window.aetherDesk._setEnvironment) {
                window.aetherDesk._setEnvironment(\(envJSON));
            }
        })();
        """
        evaluate(script, on: webView, tag: "injectEnvironment")
    }

    // MARK: Inbound (JS -> native)

    func handleJSMessages(action: String, data: [String: Any]) {
        switch action {
        case "getProperty":
            if let key = data["key"] as? String, let value = properties[key] {
                sendToJS(method: "propertyValue",
                         data: ["key": key, "value": value])
            }
        case "getAllProperties":
            sendToJS(method: "allProperties",
                     data: ["properties": properties])
        case "log":
            if let msg = data["message"] as? String {
                Logger.app.info("ÆtherDesk[wallpaper \(self.displayID)]: \(msg)")
            }
        default:
            break
        }
    }

    private func sendToJS(method: String, data: [String: Any]) {
        guard let webView = webView else { return }
        let messageJSON = jsonFragment(["method": method, "data": data] as [String: Any])
        let script = """
        (function() {
            if (window._aetherDeskHandleMessage) {
                window._aetherDeskHandleMessage(\(messageJSON));
            }
        })();
        """
        evaluate(script, on: webView, tag: "sendToJS(\(method))")
    }

    // MARK: JSON + eval helpers

    /// JSON-encodes *any* value including atoms (int, double, bool, string,
    /// null). `JSONSerialization` refuses fragments at top level, so we wrap
    /// the value in a single-element array, serialize, and peel the array off.
    private func jsonFragment(_ value: Any) -> String {
        if let s = value as? String {
            return escapeJSONString(s)
        }
        if let b = value as? Bool {
            return b ? "true" : "false"
        }
        if let i = value as? Int {
            return String(i)
        }
        if let d = value as? Double {
            if d.isFinite { return String(d) } else { return "null" }
        }
        if let arr = value as? [Any] {
            if let data = try? JSONSerialization.data(withJSONObject: arr,
                                                     options: [.fragmentsAllowed]),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "[]"
        }
        if let dict = value as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.fragmentsAllowed]),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "{}"
        }
        // Fallback: wrap in a 1-element array and peel.
        if let data = try? JSONSerialization.data(withJSONObject: [value],
                                                  options: [.fragmentsAllowed]),
           let s = String(data: data, encoding: .utf8),
           s.count > 2 {
            let start = s.index(after: s.startIndex)
            let end = s.index(before: s.endIndex)
            return String(s[start..<end])
        }
        return "null"
    }

    /// Produce a JSON-quoted string literal with the correct escaping. Used
    /// instead of JSONEncoder(String) because top-level JSON fragment support
    /// varies by Swift version and target OS.
    private func escapeJSONString(_ s: String) -> String {
        var out = "\""
        out.reserveCapacity(s.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\u{00}"..."\u{1F}":
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }

    private func evaluate(_ js: String, on webView: WKWebView, tag: String) {
        if Thread.isMainThread {
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    Logger.app.error("ÆtherDesk: \(tag)iled: \(String(describing: error))")
                }
            }
        } else {
            DispatchQueue.main.async { [weak webView] in
                guard let wv = webView else { return }
                wv.evaluateJavaScript(js) { _, error in
                    if let error = error {
                        Logger.app.error("ÆtherDesk: \(tag)iled: \(String(describing: error))")
                    }
                }
            }
        }
    }
}
