import Foundation
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
    private var properties: [String: Any] = [:]
    private weak var webView: WKWebView?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init()
    }

    // MARK: Setup

    func setWebView(_ webView: WKWebView) {
        self.webView = webView
    }

    func setInitialProperties(_ livelyProperties: [LivelyProperty]) {
        for prop in livelyProperties {
            properties[prop.name] = prop.value.value
        }
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
        })();
        """
        evaluate(script, on: webView, tag: "injectProperties")
    }

    /// Push a single property delta into the page.
    func updateProperty(_ key: String, value: Any) {
        properties[key] = value
        guard let webView = webView else { return }
        let keyJSON = jsonFragment(key)
        let valJSON = jsonFragment(value)
        let script = """
        (function() {
            window._aetherDeskProperties = window._aetherDeskProperties || {};
            window._aetherDeskProperties[\(keyJSON)] = \(valJSON);
            if (window.aetherDesk && window.aetherDesk._notify) {
                window.aetherDesk._notify(window._aetherDeskProperties);
            }
        })();
        """
        evaluate(script, on: webView, tag: "updateProperty(\(key))")
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
        let systemDict: [String: Any] = [
            "isLowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "isOnline":       true,
            "fpsCap":         Constants.Defaults.fpsCap,
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
                NSLog("AetherDesk[wallpaper %u]: %@", displayID, msg)
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
                    NSLog("AetherDesk: %@ failed: %@", tag, String(describing: error))
                }
            }
        } else {
            DispatchQueue.main.async { [weak webView] in
                guard let wv = webView else { return }
                wv.evaluateJavaScript(js) { _, error in
                    if let error = error {
                        NSLog("AetherDesk: %@ failed: %@", tag, String(describing: error))
                    }
                }
            }
        }
    }
}
