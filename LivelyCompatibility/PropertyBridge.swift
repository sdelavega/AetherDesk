import Foundation
import WebKit

class PropertyBridge: NSObject {

    private let displayID: CGDirectDisplayID
    private var properties: [String: Any] = [:]
    private weak var webView: WKWebView?
    private var propertyUpdateHandler: ((String, Any) -> Void)?

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        super.init()
    }

    func setWebView(_ webView: WKWebView) {
        self.webView = webView
    }

    func setInitialProperties(_ livelyProperties: [LivelyProperty]) {
        for prop in livelyProperties {
            properties[prop.name] = prop.value.value
        }
    }

    func updateProperty(_ key: String, value: Any) {
        properties[key] = value
        injectProperty(key: key, value: value)
    }

    func injectProperties() {
        guard let webView = webView else { return }

        let script = createInjectScript()
        webView.evaluateJavaScript(script) { _, error in
            if let error = error {
                print("AetherDesk: Failed to inject properties: \(error)")
            }
        }
    }

    func handleJSMessages(action: String, data: [String: Any]) {
        switch action {
        case "getProperty":
            if let key = data["key"] as? String,
               let value = properties[key] {
                sendToJS(method: "propertyValue", data: ["key": key, "value": value])
            }
        case "getAllProperties":
            sendToJS(method: "allProperties", data: ["properties": properties])
        default:
            break
        }
    }

    private func injectProperty(key: String, value: Any) {
        guard let webView = webView else { return }

        let script = """
        (function() {
            if (window._aetherDeskProperties) {
                window._aetherDeskProperties['\(key)'] = \(encodeJSON(value));
                if (window._aetherDeskPropertyCallback) {
                    window._aetherDeskPropertyCallback(window._aetherDeskProperties);
                }
            }
        })();
        """

        webView.evaluateJavaScript(script) { _, error in
            if let error = error {
                print("AetherDesk: Failed to inject property \(key): \(error)")
            }
        }
    }

    private func createInjectScript() -> String {
        let propertiesJSON = encodeJSON(properties)
        return """
        (function() {
            window._aetherDeskProperties = \(propertiesJSON);
        })();
        """
    }

    private func sendToJS(method: String, data: [String: Any]) {
        guard let webView = webView else { return }

        let message: [String: Any] = ["method": method, "data": data]
        let messageJSON = encodeJSON(message)

        let script = """
        (function() {
            window._aetherDeskHandleMessage(\(messageJSON));
        })();
        """

        webView.evaluateJavaScript(script) { _, error in
            if let error = error {
                print("AetherDesk: Failed to send message to JS: \(error)")
            }
        }
    }

    private func encodeJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
