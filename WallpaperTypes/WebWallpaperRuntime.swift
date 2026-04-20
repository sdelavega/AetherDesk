import AppKit
import WebKit
import Foundation

class WebWallpaperRuntime: NSObject, WallpaperRuntime {

    let displayID: CGDirectDisplayID
    private(set) var isPaused: Bool = false

    private let bundle: WallpaperBundle
    private var webView: WKWebView!
    private var propertyBridge: PropertyBridge!
    private var configuration: WKWebViewConfiguration!
    private var userContentController: WKUserContentController!

    var contentView: NSView {
        return webView
    }

    init(bundle: WallpaperBundle, displayID: CGDirectDisplayID) {
        self.bundle = bundle
        self.displayID = displayID
        super.init()

        setupWebView()
        setupPropertyBridge()
    }

    func start() throws {
        guard let indexURL = bundle.indexURL else {
            throw WallpaperRuntimeError.contentNotFound
        }

        webView.loadFileURL(indexURL, allowingReadAccessTo: bundle.baseURL)
    }

    func pause() {
        isPaused = true
        webView.isHidden = true
    }

    func resume() {
        isPaused = false
        webView.isHidden = false
    }

    func stop() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    func updateProperty(_ key: String, value: Any) {
        propertyBridge.updateProperty(key, value: value)
    }

    func reload() throws {
        stop()
        try start()
    }

    private func setupWebView() {
        userContentController = WKUserContentController()

        let scriptMessageHandler = ScriptMessageHandler(bridge: nil)
        userContentController.addUserScript(WKUserScript(
            source: createBridgeScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        userContentController.add(scriptMessageHandler, name: "aetherDesk")

        configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        // Use WKWebpagePreferences to control JavaScript on a per-navigation basis (modern API)
        let pagePrefs = WKWebpagePreferences()
        pagePrefs.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = pagePrefs

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        // Make background transparent on macOS
        webView.setValue(false, forKey: "drawsBackground")
        webView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func setupPropertyBridge() {
        propertyBridge = PropertyBridge(displayID: displayID)

        // Register bridge with existing script message handler if needed
        configuration.userContentController.removeScriptMessageHandler(forName: "aetherDesk")
        let handler = ScriptMessageHandler(bridge: propertyBridge)
        configuration.userContentController.add(handler, name: "aetherDesk")
    }

    private func createBridgeScript() -> String {
        return """
        (function() {
            window.aetherDesk = {
                properties: {
                    _handlers: {},
                    get: function() { return window._aetherDeskProperties || {}; },
                    onUpdate: function(callback) {
                        window._aetherDeskPropertyCallback = callback;
                    },
                    _notify: function(props) {
                        window._aetherDeskProperties = props;
                        if (window._aetherDeskPropertyCallback) {
                            window._aetherDeskPropertyCallback(props);
                        }
                    }
                },
                display: {
                    width: \(NSScreen.screens.first?.frame.width ?? 1920),
                    height: \(NSScreen.screens.first?.frame.height ?? 1080),
                    scaleFactor: \(NSScreen.screens.first?.backingScaleFactor ?? 2.0),
                    id: \(displayID),
                    isPrimary: \(CGDisplayIsMain(displayID) != 0)
                },
                system: {
                    isLowPowerMode: false,
                    isOnline: true,
                    fpsCap: 30,
                    qualityMode: 'balanced'
                },
                wallpaper: {
                    setFPS: function(fps) {},
                    getFPS: function() { return 30; }
                }
            };
        })();
        """
    }
}

extension WebWallpaperRuntime: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let bundleProperties = bundle.properties {
            propertyBridge.setInitialProperties(bundleProperties)
            propertyBridge.injectProperties()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("AetherDesk: WebView navigation failed: \(error)")
    }
}

private class ScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var bridge: PropertyBridge?

    init(bridge: PropertyBridge?) {
        self.bridge = bridge
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "aetherDesk",
           let body = message.body as? [String: Any],
           let action = body["action"] as? String {
            bridge?.handleJSMessages(action: action, data: body)
        }
    }
}
