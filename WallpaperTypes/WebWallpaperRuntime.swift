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

import AppKit
import os.log
import WebKit
import Foundation
import CoreLocation

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

    /// Custom URL scheme used as the base URL when loading wallpaper HTML.
    /// Loading via loadHTMLString with this as baseURL gives the page a
    /// non-null origin so cross-origin HTTPS fetch (weather APIs, IP
    /// geolocation, etc.) passes WebKit's CORS check. Sub-resources requested
    /// via relative paths are served by BundleSchemeHandler.
    private static let bundleScheme = "aetherwall"

    let displayID: CGDirectDisplayID
    private(set) var isPaused: Bool = false

    private let bundle: WallpaperBundle
    private let policy: WallpaperRuntimePolicy
    private let settings: PerformanceSettings
    private let fpsCap: Int
    private var webView: WKWebView?
    private let propertyBridge: PropertyBridge
    private let messageHandler: ScriptMessageHandler
    private let watchdog: WatchdogTimer

    /// Stable container view returned as contentView. The actual WKWebView
    /// is added/removed as a subview during start/stop.
    private let containerView: NSView

    /// Tracks rapid web content process crashes so we can retry once before
    /// giving up and demoting to safe mode.
    private var lastTerminationUptime: TimeInterval = 0
    private var rapidTerminationCount: Int = 0

    private var networkWindowStart = Date()
    private var networkRequestsInWindow = 0
    private var nativeFetchWindowStart = Date()
    private var nativeFetchRequestsInWindow = 0
    private let locationProxy: LocationProxy
    private let networkPolicy: NetworkPolicy
    private var isStopped = false
    private var initialOverrides: [String: Any] = [:]
    private let pausedSnapshotView: NSImageView
    private var pendingPauseSnapshotID: UUID?

    var contentView: NSView { containerView }

    init(bundle: WallpaperBundle, displayID: CGDirectDisplayID) {
        self.bundle = bundle
        self.displayID = displayID
        self.policy = RuntimePolicyStore.shared.load(for: bundle.id)
        let settings = AppSettingsStore.shared.loadPerformanceSettings()
        self.settings = settings
        self.fpsCap = policy.effectiveFPSCap(with: settings)

        let bridge = PropertyBridge(displayID: displayID, fpsCap: fpsCap)
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
        self.networkPolicy = NetworkPolicy(
            bundleID: bundle.id,
            allowLANAccess: AppSettingsStore.shared.loadPerformanceSettings().allowLANAccess)
        self.locationProxy = LocationProxy(bundleID: bundle.id)
        self.pausedSnapshotView = NSImageView()

        super.init()

        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.autoresizingMask = [.width, .height]

        pausedSnapshotView.translatesAutoresizingMaskIntoConstraints = false
        pausedSnapshotView.imageScaling = .scaleAxesIndependently
        pausedSnapshotView.imageAlignment = .alignCenter
        pausedSnapshotView.isHidden = true

        handler.onHeartbeat = { [weak self] in self?.watchdog.heartbeat() }
        handler.onNativeFetch = { [weak self] id, urlStr, method in
            self?.performNativeFetch(id: id, urlStr: urlStr, method: method)
        }
        handler.onGeolocationRequest = { [weak self] id in
            self?.locationProxy.request(id: id)
        }
        locationProxy.onResult = { [weak self] id, lat, lon in
            self?.deliverGeolocationResult(id: id, lat: lat, lon: lon)
        }
        handler.onNetworkBudgetExceeded = { [displayID] in
            Logger.app.info("ÆtherDesk: web wallpaper on display \(displayID) its JS network budget")
        }
    }

    deinit {
        watchdog.stop()
    }

    // MARK: WebView lifecycle

    private func createWebView() -> WKWebView {
        let userContent = WKUserContentController()
        userContent.add(messageHandler, name: "aetherDesk")

        // Apply content blocker to prevent ad/tracker/miner requests.
        // The rule list is guaranteed compiled before the first WebView is
        // created (AppDelegate waits for ContentRuleListManager.prepare).
        if let ruleList = ContentRuleListManager.shared.ruleList {
            userContent.add(ruleList)
        }
        if settings.blockExternalNetwork,
           let ruleList = ContentRuleListManager.shared.externalNetworkBlockRuleList {
            userContent.add(ruleList)
        }
        if let ruleList = ContentRuleListManager.shared.rawIPWebSocketRuleList {
            userContent.add(ruleList)
        }

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        config.setURLSchemeHandler(
            BundleSchemeHandler(bundleBaseURL: bundle.baseURL),
            forURLScheme: Self.bundleScheme
        )

        if #available(macOS 12.3, *) {
            config.preferences.isElementFullscreenEnabled = false
        }

        let bootstrap = WKUserScript(
            source: Self.bridgeBootstrapScript(
                displayID: displayID,
                heartbeatInterval: Constants.Defaults.watchdogHeartbeatInterval,
                fpsCap: fpsCap,
                networkBudgetPerMinute: policy.networkBudgetPerMinute),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        userContent.addUserScript(bootstrap)

        #if AETHERDESK_STORE
        // Seed window.__weatherKitActive with an initial guess (true: "we're
        // attempting WeatherKit") before any page JS runs, so wallpapers have
        // a synchronously-readable value during their own init. This is only
        // a starting guess, not the source of truth — the real, per-fetch
        // answer arrives later via _nativeFetchResponse (see bridgeBootstrapScript
        // above), which overwrites this flag with "weatherkit" or "open-meteo"
        // based on what each forecast request actually used, including the
        // silent URLSession fallback when WeatherKit is unavailable. Wallpapers
        // that want an accurate attribution should re-check the flag after each
        // fetch resolves (WeatherAether does this from applyWeather()).
        let weatherKitFlag = WKUserScript(
            source: "window.__weatherKitActive = true;",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        userContent.addUserScript(weatherKitFlag)
        #endif

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.wantsLayer = true
        wv.layer?.backgroundColor = NSColor.clear.cgColor
        wv.allowsMagnification = false
        wv.allowsBackForwardNavigationGestures = false

        propertyBridge.setWebView(wv)
        return wv
    }

    // MARK: WallpaperRuntime

    func setInitialOverrides(_ overrides: [String: Any]) {
        initialOverrides = overrides
    }

    func start() throws {
        isStopped = false
        guard let indexURL = bundle.indexURL else {
            throw WallpaperRuntimeError.contentNotFound
        }
        resetNetworkWindow()
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
        // Load the HTML as a string with a unique aetherwall://<bundleID>/ base URL.
        // loadHTMLString renders exactly like loadFileURL (no scheme-handler
        // round-trip for the main frame, so no display regression), but the
        // page's origin becomes aetherwall://<bundleID> instead of null/file://,
        // which lets cross-origin HTTPS fetch() calls pass WebKit's CORS check.
        // The unique host per bundle isolates localStorage/cookies/IndexedDB.
        // Sub-resources with relative paths are served by BundleSchemeHandler.
        // Fall back to loadFileURL if the HTML can't be read as a string.
        if let html = try? String(contentsOf: indexURL, encoding: .utf8) {
            let baseURL = URL(string: "\(Self.bundleScheme)://\(bundle.id.uuidString)/")!
            webView?.loadHTMLString(html, baseURL: baseURL)
        } else {
            webView?.loadFileURL(indexURL, allowingReadAccessTo: bundle.baseURL)
        }
        watchdog.start()
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        watchdog.stop()

        guard let webView else { return }
        propertyBridge.flushNow()
        initialOverrides = propertyBridge.currentProperties()

        webView.evaluateJavaScript(
            """
            if (window.aetherDesk) {
                window.aetherDesk._notifyVisibility && window.aetherDesk._notifyVisibility(false);
                window.aetherDesk._suspend && window.aetherDesk._suspend();
            }
            """,
            completionHandler: { [weak self] _, _ in
                self?.freezeAndTearDownWebViewIfStillPaused(webView)
            }
        )
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        pendingPauseSnapshotID = nil
        removePausedSnapshot()

        if let webView {
            webView.evaluateJavaScript(
                """
                if (window.aetherDesk) {
                    window.aetherDesk._resume && window.aetherDesk._resume();
                    window.aetherDesk._notifyVisibility && window.aetherDesk._notifyVisibility(true);
                }
                """,
                completionHandler: nil
            )
            watchdog.start()
            return
        }

        do {
            try start()
        } catch {
            Logger.app.error("ÆtherDesk: failed to resume web wallpaper on display \(self.displayID): \(String(describing: error))")
            NotificationCenter.default.post(
                name: Constants.Notifications.runtimeDidFail,
                object: nil,
                userInfo: ["displayID": displayID,
                           "reason": "resume failed"]
            )
        }
    }

    func stop() {
        isStopped = true
        watchdog.stop()
        pendingPauseSnapshotID = nil
        removePausedSnapshot()
        propertyBridge.flushNow()
        tearDownWebView()
    }

    func reload() throws {
        stop()
        try start()
    }

    func updateProperty(_ key: String, value: Any) {
        propertyBridge.updateProperty(key, value: value)
    }

    private func freezeAndTearDownWebViewIfStillPaused(_ webView: WKWebView) {
        let snapshotID = UUID()
        pendingPauseSnapshotID = snapshotID

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = webView.bounds
        webView.takeSnapshot(with: snapshotConfig) { [weak self] image, _ in
            guard let self,
                  self.isPaused,
                  self.pendingPauseSnapshotID == snapshotID else { return }
            if let image {
                self.installPausedSnapshot(image)
            }
            if self.webView === webView {
                self.tearDownWebView()
            }
        }
    }

    private func installPausedSnapshot(_ image: NSImage) {
        pausedSnapshotView.image = image
        if pausedSnapshotView.superview == nil {
            containerView.addSubview(pausedSnapshotView)
            NSLayoutConstraint.activate([
                pausedSnapshotView.topAnchor.constraint(equalTo: containerView.topAnchor),
                pausedSnapshotView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
                pausedSnapshotView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                pausedSnapshotView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor)
            ])
        }
        pausedSnapshotView.isHidden = false
    }

    private func removePausedSnapshot() {
        pausedSnapshotView.isHidden = true
        pausedSnapshotView.image = nil
    }

    private func tearDownWebView() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        propertyBridge.setWebView(nil)
    }

    // MARK: Native fetch proxy

    /// Executes an HTTP request via URLSession on behalf of the wallpaper page,
    /// completely bypassing WebKit's cross-origin restrictions so wallpapers
    /// can reach external APIs (weather data, geolocation, etc.).
    private func performNativeFetch(id: Int, urlStr: String, method: String) {
        guard let url = URL(string: urlStr) else {
            deliverFetchResult(id: id, status: 0, body: nil)
            return
        }

        guard consumeNativeFetchBudget() else {
            Logger.app.warning("ÆtherDesk: blocked wallpaper fetch — native fetch budget exceeded on display \(self.displayID)")
            deliverFetchResult(id: id, status: 0, body: nil)
            return
        }

        // In App Store builds, intercept weather API calls and fulfil them via
        // WeatherKit instead of forwarding to open-meteo over URLSession.
        #if AETHERDESK_STORE
        if WeatherKitBridge.shouldIntercept(url) {
            WeatherKitBridge.shared.fetch(url: url) { [weak self] status, body, usedWeatherKit in
                // Only stamp a source when the request actually succeeded; on
                // failure (status 0) there's no data to attribute either way.
                let source: String? = status == 0 ? nil : (usedWeatherKit ? "weatherkit" : "open-meteo")
                self?.deliverFetchResult(id: id, status: status, body: body, weatherSource: source)
            }
            return
        }
        #endif

        switch networkPolicy.validate(url: url) {
        case .success(let validatedURL):
            // DNS resolution (getaddrinfo) is synchronous and can block for
            // seconds on slow/unreachable servers — move it off the main thread.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                switch self.networkPolicy.validateResolvedAddresses(for: validatedURL) {
                case .success(let safeURL):
                    var request = URLRequest(url: safeURL, timeoutInterval: 30)
                    request.httpMethod = method
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    URLSession.shared.downloadTask(with: request) { [weak self] tempURL, response, error in
                        let status: Int
                        if error != nil {
                            status = 0
                        } else {
                            status = (response as? HTTPURLResponse)?.statusCode ?? 200
                        }
                        let body: String? = {
                            guard let tempURL = tempURL else { return nil }
                            let fm = FileManager.default
                            guard let attrs = try? fm.attributesOfItem(atPath: tempURL.path),
                                  let fileSize = attrs[.size] as? Int64,
                                  fileSize <= Constants.Defaults.maxNativeFetchResponseBytes else {
                                let actualSize = (try? fm.attributesOfItem(atPath: tempURL.path))?[.size] as? Int64 ?? -1
                                Logger.app.warning("ÆtherDesk: rejected oversized fetch response (\(actualSize)ytes)")
                                return nil
                            }
                            guard let data = try? Data(contentsOf: tempURL) else { return nil }
                            return String(data: data, encoding: .utf8)
                        }()
                        self?.deliverFetchResult(id: id, status: status, body: body)
                    }.resume()
                case .failure(let reason):
                    Logger.app.warning("ÆtherDesk: blocked wallpaper fetch — \(reason.description)")
                    self.deliverFetchResult(id: id, status: 0, body: nil)
                }
            }
        case .failure(let reason):
            Logger.app.warning("ÆtherDesk: blocked wallpaper fetch — \(reason.description)")
            deliverFetchResult(id: id, status: 0, body: nil)
        }
    }

    private func deliverGeolocationResult(id: Int, lat: Double?, lon: Double?) {
        let js: String
        if let lat = lat, let lon = lon {
            js = "window.aetherDesk && window.aetherDesk._geolocationSuccess(\(id), \(lat), \(lon))"
        } else {
            js = "window.aetherDesk && window.aetherDesk._geolocationError(\(id))"
        }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    /// `weatherSource`, when non-nil, is one of "weatherkit" / "open-meteo" and
    /// tells the JS layer which provider actually produced this response so
    /// WeatherAether's attribution credit line can reflect reality rather than
    /// a static build-time guess. Only the WeatherKitBridge interception path
    /// (App Store builds) ever passes a non-nil value.
    private func deliverFetchResult(id: Int, status: Int, body: String?, weatherSource: String? = nil) {
        var payload: [String: Any] = ["id": id, "status": status, "body": body ?? ""]
        if let weatherSource {
            payload["weatherSource"] = weatherSource
        }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload),
              let jsonStr = String(data: jsonData, encoding: .utf8) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(
                "window.aetherDesk && window.aetherDesk._nativeFetchResponse(\(jsonStr))",
                completionHandler: nil
            )
        }
    }

    // MARK: Bridge bootstrap

    private static func bridgeBootstrapScript(displayID: CGDirectDisplayID,
                                              heartbeatInterval: TimeInterval,
                                              fpsCap: Int,
                                              networkBudgetPerMinute: Int?) -> String {
        // Note: display geometry & scale are injected lazily via
        // `window.aetherDesk._setEnvironment` from Swift so we don't race
        // `NSScreen.screens` at WKUserScript compile time.
        let intervalMs = Int(heartbeatInterval * 1000)
        let clampedFPS = min(Constants.Defaults.maxFPS,
                             max(Constants.Defaults.minFPS, fpsCap))
        let networkBudget = networkBudgetPerMinute ?? -1
        return """
        (function() {
            if (window.aetherDesk) return;
            var callbacks = { property: null, visibility: null };
            var suspended = false;
            var networkBudgetPerMinute = \(networkBudget);
            var networkWindowStart = Date.now();
            var networkRequestsInWindow = 0;
            var _pendingFetches = {};
            var _fetchIdCounter = 0;
            var _lastWeatherSourceFetchId = -1;
            window._aetherDeskProperties = window._aetherDeskProperties || {};
            window.aetherDesk = {
                display: { id: \(displayID), width: 0, height: 0, scaleFactor: 1, isPrimary: false },
                system:  { isLowPowerMode: false, isOnline: navigator.onLine, qualityMode: 'balanced' },
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
                },
                _consumeNetworkBudget: function() {
                    if (networkBudgetPerMinute < 0) return true;
                    var now = Date.now();
                    if (now - networkWindowStart >= 60000) {
                        networkWindowStart = now;
                        networkRequestsInWindow = 0;
                    }
                    if (networkRequestsInWindow >= networkBudgetPerMinute) return false;
                    networkRequestsInWindow += 1;
                    return true;
                },
                // Called by native code with the URLSession response for a proxied fetch.
                _nativeFetchResponse: function(resp) {
                    // App Store builds: native side tells us per-request whether
                    // this particular response came from WeatherKit or the
                    // Open-Meteo fallback. Set the flag before resolving so any
                    // .then() handler (e.g. applyWeather -> setupAttribution)
                    // sees the correct, per-fetch value rather than a stale
                    // build-time guess.
                    //
                    // Wallpapers can have multiple weather fetches in flight at
                    // once (e.g. WeatherAether fires one immediately from a
                    // cached location and another after geolocation resolves,
                    // which can land a few seconds later). Responses aren't
                    // guaranteed to arrive in the order they were issued, so a
                    // slower, older fetch landing after a newer one must not be
                    // allowed to stomp on the flag. `id` is assigned when the
                    // fetch is issued (see window.fetch override below) and is
                    // monotonically increasing, so it's a reliable "is this
                    // newer than what I've already applied" check.
                    if (resp.weatherSource !== undefined && resp.id > _lastWeatherSourceFetchId) {
                        _lastWeatherSourceFetchId = resp.id;
                        if (resp.weatherSource === 'weatherkit') {
                            window.__weatherKitActive = true;
                        } else if (resp.weatherSource === 'open-meteo') {
                            window.__weatherKitActive = false;
                        }
                    }
                    var pending = _pendingFetches[resp.id];
                    if (!pending) return;
                    delete _pendingFetches[resp.id];
                    if (resp.status === 0) {
                        pending.reject(new TypeError('Network request failed'));
                        return;
                    }
                    try {
                        pending.resolve(new Response(resp.body, { status: resp.status }));
                    } catch(e) {
                        pending.reject(e);
                    }
                }
            };
            try {
                Object.defineProperty(window.aetherDesk.system, 'fpsCap', {
                    value: \(clampedFPS),
                    writable: false,
                    configurable: false
                });
            } catch (e) {}

            function networkBlockedError() {
                try {
                    window.webkit && window.webkit.messageHandlers &&
                    window.webkit.messageHandlers.aetherDesk &&
                    window.webkit.messageHandlers.aetherDesk.postMessage(
                        { action: 'networkBudgetExceeded' });
                } catch (e) {}
                return new Error('ÆtherDesk network budget exceeded');
            }

            if (typeof window.fetch === 'function') {
                var _origFetch = window.fetch.bind(window);
                window.fetch = function(resource, options) {
                    if (!window.aetherDesk._consumeNetworkBudget()) {
                        return Promise.reject(networkBlockedError());
                    }
                    // Route external HTTP(S) requests through native URLSession so they
                    // aren't subject to WebKit's cross-origin restrictions on local pages.
                    var urlStr = (typeof resource === 'string') ? resource
                                 : (resource && (resource.url || String(resource)));
                    if (urlStr && (urlStr.indexOf('http://') === 0 || urlStr.indexOf('https://') === 0)) {
                        return new Promise(function(resolve, reject) {
                            var id = ++_fetchIdCounter;
                            _pendingFetches[id] = { resolve: resolve, reject: reject };
                            try {
                                window.webkit.messageHandlers.aetherDesk.postMessage({
                                    action: 'nativeFetch',
                                    id: id,
                                    url: urlStr,
                                    method: (options && options.method) || 'GET'
                                });
                            } catch (e) {
                                delete _pendingFetches[id];
                                reject(new TypeError('Native fetch bridge unavailable'));
                            }
                        });
                    }
                    return _origFetch.apply(window, arguments);
                };
            }

            if (typeof window.XMLHttpRequest === 'function') {
                var _OrigXHR = window.XMLHttpRequest;
                window.XMLHttpRequest = function() {
                    var xhr = new _OrigXHR();
                    var _open = xhr.open;
                    xhr.open = function() {
                        if (!window.aetherDesk._consumeNetworkBudget()) {
                            throw networkBlockedError();
                        }
                        return _open.apply(xhr, arguments);
                    };
                    return xhr;
                };
            }

            // rAF throttle: enforce fpsCap from the native side.
            // Uses setTimeout to sleep between frames so the JS thread
            // idles ~90% of the time at 30 fps instead of waking at
            // every display vsync (60-120 Hz).
            var _origRAF = window.requestAnimationFrame;
            var _lastFrame = 0;
            window.requestAnimationFrame = function(cb) {
                var fpsCap = (window.aetherDesk && window.aetherDesk.system.fpsCap) || 30;
                var interval = 1000.0 / fpsCap;
                var elapsed = performance.now() - _lastFrame;
                var delay = interval - elapsed;
                function fire() {
                    _origRAF.call(window, function(ts) {
                        if (suspended) return;
                        _lastFrame = ts;
                        cb(ts);
                    });
                }
                if (delay <= 4) { fire(); return 0; }
                setTimeout(fire, delay - 4);
                return 0;
            };

            // Geolocation bridge: replace navigator.geolocation with a native-backed
            // implementation that routes getCurrentPosition through CoreLocation via
            // the aetherDesk message handler, so wallpapers can auto-detect location
            // without depending on external IP-geolocation APIs.
            var _geoPending = {};
            var _geoIdCounter = 0;
            window.aetherDesk._geolocationSuccess = function(id, lat, lon) {
                var cb = _geoPending[id]; if (!cb) return; delete _geoPending[id];
                cb.success({ coords: { latitude: lat, longitude: lon, accuracy: 1000 }, timestamp: Date.now() });
            };
            window.aetherDesk._geolocationError = function(id) {
                var cb = _geoPending[id]; if (!cb) return; delete _geoPending[id];
                if (cb.error) cb.error({ code: 2, message: 'Position unavailable' });
                else if (cb.fallback) cb.fallback();
            };
            try {
                Object.defineProperty(navigator, 'geolocation', {
                    get: function() {
                        return {
                            getCurrentPosition: function(success, error) {
                                var id = ++_geoIdCounter;
                                _geoPending[id] = { success: success, error: error };
                                try {
                                    window.webkit.messageHandlers.aetherDesk.postMessage(
                                        { action: 'geolocationRequest', id: id });
                                } catch(e) {
                                    delete _geoPending[id];
                                    if (error) error({ code: 2, message: 'Bridge unavailable' });
                                }
                            },
                            watchPosition: function(success, error) {
                                var id = ++_geoIdCounter;
                                _geoPending[id] = { success: success, error: error };
                                try {
                                    window.webkit.messageHandlers.aetherDesk.postMessage(
                                        { action: 'geolocationRequest', id: id });
                                } catch(e) {
                                    delete _geoPending[id];
                                    if (error) error({ code: 2, message: 'Bridge unavailable' });
                                }
                                return id;
                            },
                            clearWatch: function(id) { delete _geoPending[id]; }
                        };
                    },
                    configurable: true
                });
            } catch(e) {}

            // WebSocket restriction: block connections to raw IP addresses.
            // Only FQDN WebSocket connections are allowed; raw IPs are rejected
            // for the same reason as HTTP fetch — they bypass DNS-based filtering.
            if (typeof window.WebSocket === 'function') {
                var _OrigWebSocket = window.WebSocket;
                var _rawIPPattern = /^(wss?:\\/\\/)?\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}/i;
                var _ipv6Pattern = /^(wss?:\\/\\/)?\\[/i;
                window.WebSocket = function(url, protocols) {
                    if (_rawIPPattern.test(url) || _ipv6Pattern.test(url)) {
                        var err = new Error('ÆtherDesk: WebSocket to raw IP addresses is not allowed');
                        throw err;
                    }
                    if (protocols !== undefined) {
                        return new _OrigWebSocket(url, protocols);
                    }
                    return new _OrigWebSocket(url);
                };
                window.WebSocket.prototype = _OrigWebSocket.prototype;
                window.WebSocket.CONNECTING = _OrigWebSocket.CONNECTING;
                window.WebSocket.OPEN = _OrigWebSocket.OPEN;
                window.WebSocket.CLOSING = _OrigWebSocket.CLOSING;
                window.WebSocket.CLOSED = _OrigWebSocket.CLOSED;
            }

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
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        // Link clicks (e.g. WeatherKit attribution) open in the default
        // browser instead of navigating the wallpaper webview.
        if navigationAction.navigationType == .linkActivated,
           url.scheme == "https" || url.scheme == "http" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }

        if shouldAllowNavigation(to: url) {
            decisionHandler(.allow)
        } else {
            Logger.app.warning("ÆtherDesk: blocked web wallpaper navigation to \(url.absoluteString)")
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Push initial environment info.
        propertyBridge.injectEnvironment()

        // Push bundle property values.
        if let props = bundle.properties {
            propertyBridge.setInitialProperties(props, overrides: initialOverrides)
            initialOverrides = [:]
        }
        propertyBridge.injectProperties()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Logger.app.error("ÆtherDesk: WebView navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Logger.app.error("ÆtherDesk: WebView provisional navigation failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Logger.app.info("ÆtherDesk: web content process terminated on display \(self.displayID)")
        watchdog.stop()
        self.webView?.removeFromSuperview()
        self.webView = nil
        propertyBridge.setWebView(nil)

        // Track rapid successive crashes. If the process crashes twice
        // within 10 seconds, demote to safe mode; otherwise, retry once.
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastTerminationUptime < 10.0 {
            rapidTerminationCount += 1
        } else {
            rapidTerminationCount = 1
        }
        lastTerminationUptime = now

        if rapidTerminationCount >= 2 {
            Logger.app.error("ÆtherDesk: web content crashed repeatedly on display \(self.displayID) — demoting to safe mode")
            NotificationCenter.default.post(
                name: Constants.Notifications.runtimeDidFail,
                object: nil,
                userInfo: ["displayID": displayID,
                           "reason": "web content process terminated repeatedly"])
        } else {
            Logger.app.info("ÆtherDesk: attempting to recover web content on display \(self.displayID)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, !self.isStopped else { return }
                do {
                    try self.start()
                } catch {
                    Logger.app.error("ÆtherDesk: recovery failed on display \(self.displayID): \(String(describing: error))")
                    NotificationCenter.default.post(
                        name: Constants.Notifications.runtimeDidFail,
                        object: nil,
                        userInfo: ["displayID": self.displayID,
                                   "reason": "recovery failed"])
                }
            }
        }
    }

    private func shouldAllowNavigation(to url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        switch scheme {
        case Self.bundleScheme, "data", "about", "blob":
            return true
        case "file":
            return shouldAllowFileNavigation(to: url)
        case "http", "https":
            guard consumeNetworkBudget() else { return false }
            switch networkPolicy.validate(url: url) {
            case .success:
                return true
            case .failure(let reason):
                Logger.app.warning("ÆtherDesk: blocked wallpaper navigation to \(url.absoluteString): \(reason)")
                return false
            }
        case "javascript":
            return false
        default:
            return false
        }
    }

    private func shouldAllowFileNavigation(to url: URL) -> Bool {
        // Restrict file:// navigation to files inside the current bundle.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let bundlePath = bundle.baseURL.resolvingSymlinksInPath().standardizedFileURL.path
        let path = resolved.path
        return path == bundlePath || path.hasPrefix(bundlePath + "/")
    }

    private func resetNetworkWindow() {
        networkWindowStart = Date()
        networkRequestsInWindow = 0
    }

    private func consumeNetworkBudget() -> Bool {
        guard let budget = policy.networkBudgetPerMinute else { return true }
        guard budget > 0 else { return false }

        let now = Date()
        if now.timeIntervalSince(networkWindowStart) >= 60 {
            networkWindowStart = now
            networkRequestsInWindow = 0
        }

        guard networkRequestsInWindow < budget else { return false }
        networkRequestsInWindow += 1
        return true
    }

    /// Enforce the same per-minute network budget on the native fetch path
    /// that the JS shim enforces for fetch()/XMLHttpRequest. Prevents a
    /// wallpaper from bypassing the budget by calling the native bridge directly.
    private func consumeNativeFetchBudget() -> Bool {
        guard let budget = policy.networkBudgetPerMinute else { return true }
        guard budget > 0 else { return false }

        let now = Date()
        if now.timeIntervalSince(nativeFetchWindowStart) >= 60 {
            nativeFetchWindowStart = now
            nativeFetchRequestsInWindow = 0
        }

        guard nativeFetchRequestsInWindow < budget else { return false }
        nativeFetchRequestsInWindow += 1
        return true
    }
}

// MARK: - CoreLocation proxy

/// Fulfils `navigator.geolocation.getCurrentPosition` requests from wallpaper JS
/// by delegating to CoreLocation. One shared instance per runtime; requests are
/// queued while a location fix is in progress so we don't spam CLLocationManager.
/// Per-wallpaper consent is checked before any location data is delivered.
private final class LocationProxy: NSObject, CLLocationManagerDelegate {

    private let manager: CLLocationManager
    private let bundleID: UUID
    /// Pending request IDs waiting for a location fix.
    private var pendingIDs: [Int] = []
    /// Called with (id, lat, lon) on success or (id, nil, nil) on failure.
    var onResult: ((_ id: Int, _ lat: Double?, _ lon: Double?) -> Void)?

    init(bundleID: UUID) {
        self.bundleID = bundleID
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func request(id: Int) {
        DispatchQueue.main.async { [self] in
            let permission = GeolocationPermissionStore.shared.load(for: bundleID)
            // .denied = user explicitly blocked via Preferences; reject immediately.
            // .allowed / .notDetermined = proceed; the system CoreLocation
            // authorization dialog (non-blocking) handles the actual grant.
            // We do NOT show a secondary app-level modal because runModal()
            // blocks the main thread and races the JS fallback timers.
            if permission == .denied {
                onResult?(id, nil, nil)
                return
            }
            pendingIDs.append(id)
            if pendingIDs.count == 1 { startUpdates() }
        }
    }

    private func startUpdates() {
        let status: CLAuthorizationStatus
        if #available(macOS 11.0, *) {
            status = manager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }
        switch status {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            flushPending(lat: nil, lon: nil)
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard !pendingIDs.isEmpty else { return }
        startUpdates()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        manager.stopUpdatingLocation()
        flushPending(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        manager.stopUpdatingLocation()
        flushPending(lat: nil, lon: nil)
    }

    private func flushPending(lat: Double?, lon: Double?) {
        let ids = pendingIDs
        pendingIDs.removeAll()
        for id in ids {
            onResult?(id, lat, lon)
        }
    }
}

// MARK: - Bundle URL scheme handler

/// Serves wallpaper bundle files over the `aetherwall://` custom scheme.
///
/// Loading via a named scheme (rather than `file://`) gives the embedded page
/// a proper origin so cross-origin HTTPS `fetch()` calls — weather APIs,
/// IP-geolocation, geocoding — pass WebKit's CORS check without any private
/// WKPreferences keys.
private final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {

    private static let maxSchemeHandlerFileSize: Int64 = 100_000_000 // 100 MB

    private let bundleBaseURL: URL

    init(bundleBaseURL: URL) {
        self.bundleBaseURL = bundleBaseURL.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        var relative = url.path
        if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
        if relative.isEmpty       { relative = "index.html" }

        let fileURL = bundleBaseURL.appendingPathComponent(relative)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let basePath = bundleBaseURL.resolvingSymlinksInPath().path
        let filePath = fileURL.path
        guard filePath == basePath || filePath.hasPrefix(basePath + "/") else {
            Logger.app.warning("ÆtherDesk: blocked path-traversal request from wallpaper: \(url.path)")
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let ext = fileURL.pathExtension
        guard let mime = Self.mimeType(for: ext) else {
            Logger.app.warning("ÆtherDesk: blocked wallpaper request for disallowed file type: .\(ext)")
            task.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? Int64 else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        guard fileSize <= Self.maxSchemeHandlerFileSize else {
            Logger.app.warning("ÆtherDesk: rejected wallpaper request for oversized file (\(fileSize)ytes): \(url.path)")
            task.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": String(fileSize),
                "X-Content-Type-Options": "nosniff",
            ])!
        task.didReceive(response)

        let streamingThreshold: Int64 = 1_048_576
        if fileSize <= streamingThreshold {
            guard let data = try? Data(contentsOf: fileURL) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            task.didReceive(data)
            task.didFinish()
        } else {
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
                task.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let chunkSize = 512 * 1024
            var done = false
            while !done {
                autoreleasepool {
                    guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                        done = true
                        return
                    }
                    task.didReceive(chunk)
                }
            }
            try? handle.close()
            task.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        // File reads are synchronous; nothing to cancel.
    }

    private static func mimeType(for ext: String) -> String? {
        switch ext.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs":   return "text/javascript"
        case "css":         return "text/css"
        case "json":        return "application/json"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "svg":         return "image/svg+xml"
        case "webp":        return "image/webp"
        case "ico":         return "image/x-icon"
        case "bmp":         return "image/bmp"
        case "mp4", "m4v":  return "video/mp4"
        case "webm":        return "video/webm"
        case "mov":         return "video/quicktime"
        case "mp3":         return "audio/mpeg"
        case "ogg", "oga":  return "audio/ogg"
        case "wav":         return "audio/wav"
        case "m4a":         return "audio/mp4"
        case "woff2":       return "font/woff2"
        case "woff":        return "font/woff"
        case "ttf":         return "font/ttf"
        case "otf":         return "font/otf"
        case "eot":         return "application/vnd.ms-fontobject"
        case "webmanifest": return "application/manifest+json"
        case "xml":         return "application/xml"
        case "txt":         return "text/plain"
        default:            return nil
        }
    }
}

// MARK: - JS -> native message handler

private final class ScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: PropertyBridge?

    /// Fired on every `{action:"heartbeat"}` message from the page.
    var onHeartbeat: (() -> Void)?
    var onNetworkBudgetExceeded: (() -> Void)?
    var onNativeFetch: ((_ id: Int, _ url: String, _ method: String) -> Void)?
    var onGeolocationRequest: ((_ id: Int) -> Void)?

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
        if action == "networkBudgetExceeded" {
            onNetworkBudgetExceeded?()
            return
        }
        if action == "nativeFetch",
           let id = body["id"] as? Int,
           let urlStr = body["url"] as? String {
            let method = body["method"] as? String ?? "GET"
            onNativeFetch?(id, urlStr, method)
            return
        }
        if action == "geolocationRequest",
           let id = body["id"] as? Int {
            onGeolocationRequest?(id)
            return
        }
        bridge?.handleJSMessages(action: action, data: body)
    }
}
