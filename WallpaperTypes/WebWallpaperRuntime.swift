import AppKit
import WebKit
import Foundation

/// WKWebView-backed HTML/JS wallpaper runtime.
///
/// Contract with the wallpaper JS:
///   - `window.aetherDesk.properties.get()` returns the current property dict.
///   - `window.aetherDesk.properties.onUpdate(cb)` registers a callback that
///     is invoked whenever the host pushes new property values.
///   - `window.aetherDesk.system` exposes low-power / online / fps cap state.
///
/// Properties defined by the bundle's `LivelyProperties.json` are injected
/// into the page as soon as navigation finishes (`didFinish`). Subsequent
/// live updates flow through `PropertyBridge`.
///
/// Watchdog:
///   A `setInterval` in the injected bootstrap pings
///   `webkit.messageHandlers.aetherDesk` with `{action:"heartbeat"}` every
///   `watchdogHeartbeatInterval` seconds. The native side resets a
///   `WatchdogTimer`; if the timer trips (no heartbeat for
///   `watchdogTimeout` seconds), or if `webContentProcessDidTerminate` fires,
///   we post `runtimeDidFail` so the manager can demote the display.
final class WebWallpaperRuntime: NSObject, WallpaperRuntime {

    let displayID: CGDirectDisplayID
    private(set) var isPaused: Bool = false

    private let bundle: WallpaperBundle
    private var webView: WKWebView?
    private let propertyBridge: PropertyBridge
    private let messageHandler: ScriptMessageHandler
    private let watchdog: WatchdogTimer

    /// Stable container view returned as contentView. The actual WKWebView
    /// is added/removed as a subview during start/stop.
    private let containerView: NSView

    var contentView: NSView { containerView }

    init(bundle: WallpaperBundle, displayID: CGDirectDisplayID) {
        self.bundle = bundle
        self.displayID = displayID

        let bridge = PropertyBridge(displayID: displayID)
        self.propertyBridge = bridge

        let handler = ScriptMessageHandler(bridge: bridge)
        self.messageHandler = handler

        self.watchdog = WatchdogTimer(
            timeout: Constants.Defaults.watchdogTimeout,
            onTimeout: { [displayID] in
                NotificationCenter.default.post(
                    name: Constants.Notifications.runtimeDidFail,
                    object: nil,
                    userInfo: ["displayID": displayID,
                               "reason": "watchdog timeout"])
            })

        self.containerView = NSView()

        super.init()

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.autoresizingMask = [.width, .height]

        handler.onHeartbeat = { [weak self] in self?.watchdog.heartbeat() }
    }

    deinit {
        watchdog.stop()
    }

    // MARK: WebView lifecycle

    private func createWebView() -> WKWebView {
        let userContent = WKUserContentController()
        userContent.add(messageHandler, name: "aetherDesk")

        let config = WKWebViewConfiguration()
        config.userContentController = userContent

        if #available(macOS 12.3, *) {
            config.preferences.isElementFullscreenEnabled = false
        }

        let bootstrap = WKUserScript(
            source: Self.bridgeBootstrapScript(
                displayID: displayID,
                heartbeatInterval: Constants.Defaults.watchdogHeartbeatInterval),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        userContent.addUserScript(bootstrap)

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        wv.wantsLayer = true
        wv.layer?.backgroundColor = NSColor.clear.cgColor
        wv.allowsMagnification = false
        wv.allowsBackForwardNavigationGestures = false

        propertyBridge.setWebView(wv)
        return wv
    }

    // MARK: WallpaperRuntime

    func start() throws {
        guard let indexURL = bundle.indexURL else {
            throw WallpaperRuntimeError.contentNotFound
        }
        if webView == nil {
            let wv = createWebView()
            containerView.subviews.forEach { $0.removeFromSuperview() }
            wv.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(wv)
            NSLayoutConstraint.activate([
                wv.topAnchor.constraint(equalTo: containerView.topAnchor),
                wv.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                wv.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                wv.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            ])
            self.webView = wv
        }
        webView?.loadFileURL(indexURL, allowingReadAccessTo: bundle.baseURL)
        watchdog.start()
    }

    func pause() {
        isPaused = true
        watchdog.stop()
        webView?.evaluateJavaScript(
            """
            if (window.aetherDesk) {
                window.aetherDesk._notifyVisibility && window.aetherDesk._notifyVisibility(false);
                window.aetherDesk._suspend && window.aetherDesk._suspend();
            }
            """,
            completionHandler: nil
        )
        webView?.isHidden = true
    }

    func resume() {
        isPaused = false
        webView?.isHidden = false
        webView?.evaluateJavaScript(
            """
            if (window.aetherDesk) {
                window.aetherDesk._resume && window.aetherDesk._resume();
                window.aetherDesk._notifyVisibility && window.aetherDesk._notifyVisibility(true);
            }
            """,
            completionHandler: nil
        )
        watchdog.start()
    }

    func stop() {
        watchdog.stop()
        propertyBridge.flushNow()
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        propertyBridge.setWebView(nil)
    }

    func reload() throws {
        stop()
        try start()
    }

    func updateProperty(_ key: String, value: Any) {
        propertyBridge.updateProperty(key, value: value)
    }

    // MARK: Bridge bootstrap

    private static func bridgeBootstrapScript(displayID: CGDirectDisplayID,
                                              heartbeatInterval: TimeInterval) -> String {
        // Note: display geometry & scale are injected lazily via
        // `window.aetherDesk._setEnvironment` from Swift so we don't race
        // `NSScreen.screens` at WKUserScript compile time.
        let intervalMs = Int(heartbeatInterval * 1000)
        return """
        (function() {
            if (window.aetherDesk) return;
            var callbacks = { property: null, visibility: null };
            var suspended = false;
            var savedTimers = { timeouts: [], intervals: [] };
            window._aetherDeskProperties = window._aetherDeskProperties || {};
            window.aetherDesk = {
                display: { id: \(displayID), width: 0, height: 0, scaleFactor: 1, isPrimary: false },
                system:  { isLowPowerMode: false, isOnline: navigator.onLine, fpsCap: 30, qualityMode: 'balanced' },
                properties: {
                    get: function() { return window._aetherDeskProperties || {}; },
                    onUpdate: function(cb) { callbacks.property = cb; }
                },
                _notify: function(props) {
                    window._aetherDeskProperties = props || {};
                    if (callbacks.property) callbacks.property(window._aetherDeskProperties);
                },
                _notifyVisibility: function(visible) {
                    if (callbacks.visibility) callbacks.visibility(visible);
                },
                _setEnvironment: function(env) {
                    Object.assign(window.aetherDesk.display, env.display || {});
                    Object.assign(window.aetherDesk.system,  env.system  || {});
                },
                onVisibility: function(cb) { callbacks.visibility = cb; },
                _suspend: function() {
                    suspended = true;
                },
                _resume: function() {
                    suspended = false;
                }
            };

            // rAF throttle: enforce fpsCap from the native side.
            var _origRAF = window.requestAnimationFrame;
            var _lastFrame = 0;
            window.requestAnimationFrame = function(cb) {
                return _origRAF.call(window, function(ts) {
                    if (suspended) return;
                    var fpsCap = (window.aetherDesk && window.aetherDesk.system.fpsCap) || 30;
                    var minInterval = 1000.0 / fpsCap;
                    if (ts - _lastFrame < minInterval) {
                        // Schedule for next frame instead of dropping entirely
                        _origRAF.call(window, function(ts2) { cb(ts2); });
                        return;
                    }
                    _lastFrame = ts;
                    cb(ts);
                });
            };

            // Watchdog heartbeat: pure setInterval, no dependency on rAF so a
            // wallpaper that stops drawing (tab throttling, bug) still pings.
            try {
                setInterval(function() {
                    try {
                        window.webkit && window.webkit.messageHandlers &&
                        window.webkit.messageHandlers.aetherDesk &&
                        window.webkit.messageHandlers.aetherDesk.postMessage(
                            { action: 'heartbeat' });
                    } catch (e) {}
                }, \(intervalMs));
            } catch (e) {}
        })();
        """
    }
}

// MARK: - Navigation delegate

extension WebWallpaperRuntime: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Push initial environment info.
        propertyBridge.injectEnvironment()

        // Push bundle property values.
        if let props = bundle.properties {
            propertyBridge.setInitialProperties(props)
        }
        propertyBridge.injectProperties()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("ÆtherDesk: WebView navigation failed: %@", error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("ÆtherDesk: WebView provisional navigation failed: %@", error.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("ÆtherDesk: web content process terminated on display %u", displayID)
        watchdog.stop()
        self.webView = nil
        propertyBridge.setWebView(nil)
        NotificationCenter.default.post(
            name: Constants.Notifications.runtimeDidFail,
            object: nil,
            userInfo: ["displayID": displayID,
                       "reason": "web content process terminated"])
    }
}

// MARK: - JS -> native message handler

private final class ScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: PropertyBridge?

    /// Fired on every `{action:"heartbeat"}` message from the page.
    var onHeartbeat: (() -> Void)?

    init(bridge: PropertyBridge?) {
        self.bridge = bridge
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "aetherDesk",
              let body = message.body as? [String: Any],
              let action = body["action"] as? String
        else { return }

        if action == "heartbeat" {
            onHeartbeat?()
            return
        }
        bridge?.handleJSMessages(action: action, data: body)
    }
}
