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

import AppKit
import WebKit

struct PerfError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let states = ["clear", "partly", "overcast", "fog", "moderate-rain", "freezing", "snow", "thunder", "hail"]

struct Options {
    var renderer = "auto"
    var seconds = 30
    var soak: Int?
    var warmup = 5
    var state: String?
    var out = "build/weather-perf-auto.json"
    var root = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        .deletingLastPathComponent().deletingLastPathComponent()

    init() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let flag = args.removeFirst()
            guard !args.isEmpty else { throw PerfError("Missing value for \(flag)") }
            let value = args.removeFirst()
            switch flag {
            case "--renderer": renderer = value
            case "--seconds": seconds = Int(value) ?? 0
            case "--soak": soak = Int(value) ?? 0
            case "--warmup": warmup = Int(value) ?? -1
            case "--state": state = value
            case "--out": out = value
            case "--root": root = URL(fileURLWithPath: value).standardizedFileURL
            default: throw PerfError("Unknown option: \(flag)")
            }
        }
        guard ["auto", "classic"].contains(renderer), seconds > 0, warmup >= 1,
              soak == nil || (soak! >= 10 && soak! % 10 == 0),
              state == nil || states.contains(state!) else {
            throw PerfError("Use --renderer auto|classic --seconds N --out file [--soak N (multiple of 10)] [--state NAME] [--warmup N] [--root path]")
        }
    }
}

func ps(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw PerfError("ps failed; WebContent may have exited") }
    return String(decoding: data, as: UTF8.self)
}

func webContentPIDs() throws -> Set<Int32> {
    Set(try ps(["-axo", "pid=,comm="]).split(separator: "\n").compactMap { line in
        guard line.contains("com.apple.WebKit.WebContent") else { return nil }
        return Int32(line.split(whereSeparator: { $0.isWhitespace }).first ?? "")
    })
}

func sample(_ pid: Int32) throws -> (cpu: Double, rss: Double) {
    let fields = try ps(["-p", String(pid), "-o", "%cpu=,rss="]).split(whereSeparator: { $0.isWhitespace })
    guard fields.count == 2, let cpu = Double(fields[0]), let rss = Double(fields[1]),
          cpu.isFinite, rss.isFinite, cpu >= 0, rss > 0 else { throw PerfError("Invalid ps sample for PID \(pid)") }
    return (cpu, rss) // ps RSS is KiB; CPU is percent of one logical core.
}

func pump(until deadline: TimeInterval) {
    while ProcessInfo.processInfo.systemUptime < deadline {
        if let event = NSApp.nextEvent(matching: .any,
                                      until: Date(timeIntervalSinceNow: min(0.05, deadline - ProcessInfo.processInfo.systemUptime)),
                                      inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        NSApp.updateWindows()
    }
}

func writeJSON(_ rows: [[String: Any]], to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
}

final class Harness: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let options: Options
    var window: NSWindow!
    var webView: WKWebView!
    var failure: String?
    var loaded = false
    var childFrame: WKFrameInfo?
    var rendererStatus: String?
    var pinnedPID: Int32?
    let initialPIDs: Set<Int32>

    init(options: Options) throws {
        self.options = options
        initialPIDs = try webContentPIDs()
        super.init()
        let controller = WKUserContentController()
        controller.add(self, name: "weatherPerf")
        // Read the production throttle verbatim so the benchmark cannot drift.
        let runtime = try String(contentsOf: options.root.appendingPathComponent("WallpaperTypes/WebWallpaperRuntime.swift"), encoding: .utf8)
        guard let start = runtime.range(of: "            // rAF throttle:"),
              let end = runtime.range(of: "            // Geolocation bridge:", range: start.upperBound..<runtime.endIndex) else {
            throw PerfError("Production rAF throttle markers changed")
        }
        let throttle = String(runtime[start.lowerBound..<end.lowerBound])
        let bootstrap = """
        (function(){
          var suspended=false;
          \(throttle)
          var throttledRAF=window.requestAnimationFrame;
          window.__perfFrames=0;var lastTimestamp=-1;
          window.requestAnimationFrame=function(cb){return throttledRAF(function(ts){
            if(ts!==lastTimestamp){window.__perfFrames++;lastTimestamp=ts;}cb(ts);
          });};
          var seed=123456789;
          Math.random=function(){seed=(1664525*seed+1013904223)>>>0;return seed/4294967296;};
          function blocked(){window.webkit.messageHandlers.weatherPerf.postMessage('Unexpected network request');
            throw new Error('WeatherPerf is offline');}
          window.fetch=function(){try{blocked();}catch(e){return Promise.reject(e);}};
          XMLHttpRequest.prototype.open=blocked;
          window.WebSocket=function(){blocked();};window.EventSource=function(){blocked();};
          navigator.sendBeacon=function(){blocked();};
          window.addEventListener('error',function(e){window.webkit.messageHandlers.weatherPerf.postMessage(e.message||'Resource load failed');},true);
          if(window.top!==window)window.addEventListener('DOMContentLoaded',function(){
            window.webkit.messageHandlers.weatherPerf.postMessage({kind:'frame'});
          });
          if(window.top===window)window.addEventListener('message',function(e){
            if(e.data&&e.data.type==='weather-aether-renderer-status')
              window.webkit.messageHandlers.weatherPerf.postMessage({kind:'status',renderer:e.data.renderer,error:e.data.error||null});
          });
        })();
        """
        controller.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()
        // A second layer blocks network subresources, not just fetch/XHR.
        let rules = """
        [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}]
        """
        var compiled = false
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "WeatherPerfOffline", encodedContentRuleList: rules) { list, error in
            if let list { controller.add(list) } else { self.failure = "Offline rules: \(String(describing: error))" }
            compiled = true
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !compiled && ProcessInfo.processInfo.systemUptime < deadline { pump(until: ProcessInfo.processInfo.systemUptime + 0.05) }
        guard compiled, failure == nil else { throw PerfError(failure ?? "Offline rule compilation timed out") }
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1920, height: 1080), configuration: config)
        webView.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: -1920, y: 0, width: 1920, height: 1080), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        // A fully offscreen NSWindow is page-hidden by WebKit. Leave a small
        // corner inside the usable display, clear of the menu bar and Dock.
        if let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 16, y: screen.visibleFrame.maxY - 16))
        }
        window.orderFrontRegardless()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] {
            if body["kind"] as? String == "frame" { childFrame = message.frameInfo; return }
            if body["kind"] as? String == "status" {
                rendererStatus = body["renderer"] as? String
                if let error = body["error"] as? String, !error.isEmpty { failure = error }
                return
            }
        }
        failure = String(describing: message.body)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error.localizedDescription }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error.localizedDescription }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { failure = "WebContent terminated" }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme
        let allowed = scheme == "file" || scheme == "about"
        if !allowed { failure = "Unexpected external navigation" }
        decisionHandler(allowed ? .allow : .cancel)
    }

    func evaluate(_ script: String) throws -> Any? {
        var done = false
        var result: Any?
        var jsError: Error?
        webView.evaluateJavaScript(script, in: childFrame, in: .page) { response in
            switch response {
            case .success(let value): result = value
            case .failure(let error): jsError = error
            }
            done = true
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !done && ProcessInfo.processInfo.systemUptime < deadline { pump(until: ProcessInfo.processInfo.systemUptime + 0.05) }
        guard done else { throw PerfError("JavaScript timed out") }
        if let jsError { throw jsError }
        if let failure { throw PerfError(failure) }
        return result
    }

    func identifyPID() throws -> Int32 {
        let current = try webContentPIDs()
        // Standalone diagnostic only: use WebKit's process accessor if available.
        // Do not ship this private selector in the app. Verify it against ps.
        if webView.responds(to: NSSelectorFromString("_webProcessIdentifier")),
           let number = webView.value(forKey: "_webProcessIdentifier") as? NSNumber,
           current.contains(number.int32Value) {
            pinnedPID = number.int32Value
            print("WebContent PID \(number) (WKWebView process accessor)")
            return number.int32Value
        }
        if let pinnedPID, current.contains(pinnedPID) { return pinnedPID }
        let candidates = current.subtracting(initialPIDs)
        guard candidates.count == 1, let pid = candidates.first else {
            throw PerfError("Cannot unambiguously attribute WebContent (\(candidates.count) new processes); close competing launches and retry")
        }
        pinnedPID = pid
        print("WebContent PID \(pid) (only new WebContent since harness launch)")
        return pid
    }

    func load(state: String, phase: String) throws -> Int32 {
        loaded = false
        failure = nil
        childFrame = nil
        rendererStatus = nil
        var url = URLComponents(url: options.root.appendingPathComponent("Tools/WeatherAetherPreview.html"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "perf", value: "1"), URLQueryItem(name: "state", value: state),
                          URLQueryItem(name: "renderer", value: options.renderer == "classic" ? "canvas" : "three"),
                          URLQueryItem(name: "hour", value: phase == "day" ? "12" : "22")]
        webView.loadFileURL(url.url!, allowingReadAccessTo: options.root)
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !loaded && failure == nil && ProcessInfo.processInfo.systemUptime < deadline { pump(until: ProcessInfo.processInfo.systemUptime + 0.05) }
        guard loaded, failure == nil else { throw PerfError(failure ?? "Preview load timed out") }
        pump(until: ProcessInfo.processInfo.systemUptime + Double(options.warmup))
        let info = try snapshot()
        guard info["renderer"] as? String == (options.renderer == "auto" ? "three" : "canvas"),
              info["width"] as? Int == 1920, info["height"] as? Int == 1080,
              info["hidden"] as? Bool == false else { throw PerfError("Preview did not render at 1920x1080: \(info)") }
        return try identifyPID()
    }

    func snapshot() throws -> [String: Any] {
        guard childFrame != nil, var value = try evaluate("""
        ({width:innerWidth,height:innerHeight,hidden:document.hidden,frames:window.__perfFrames})
        """) as? [String: Any] else { throw PerfError("Missing preview frame") }
        value["renderer"] = rendererStatus ?? "unknown"
        return value
    }

    func run() throws {
        defer { webView.stopLoading(); window.orderOut(nil); webView.configuration.userContentController.removeScriptMessageHandler(forName: "weatherPerf") }
        var rows = [[String: Any]]()
        let selectedStates = options.soak == nil ? options.state.map { [$0] } ?? states : [options.state ?? "thunder"]
        for state in selectedStates {
            for phase in options.soak == nil ? ["day", "night"] : ["night"] {
                let pid = try load(state: state, phase: phase)
                let initial = try sample(pid)
                let before = try snapshot()["frames"] as? Int ?? 0
                let start = ProcessInfo.processInfo.systemUptime
                let duration = options.soak ?? options.seconds
                let interval = options.soak == nil ? 1 : 10
                var cpu = [Double]()
                var lastRSS = initial.rss
                if options.soak != nil { rows.append(["seconds": 0, "rss": initial.rss, "renderer": options.renderer, "state": state, "phase": phase]) }
                for elapsed in stride(from: interval, through: duration, by: interval) {
                    pump(until: start + Double(elapsed))
                    if let failure { throw PerfError(failure) }
                    let value = try sample(pid)
                    cpu.append(value.cpu)
                    lastRSS = value.rss
                    if options.soak != nil {
                        rows.append(["seconds": elapsed, "rss": lastRSS, "renderer": options.renderer, "state": state, "phase": phase])
                        try writeJSON(rows, to: options.out)
                        print("soak \(elapsed)s RSS \(Int(lastRSS)) KiB")
                    }
                }
                let after = try snapshot()["frames"] as? Int ?? 0
                let fps = Double(after - before) / (ProcessInfo.processInfo.systemUptime - start)
                guard fps >= 15, fps <= 35 else { throw PerfError("Invalid live frame rate \(fps); occluded or unthrottled view") }
                if options.soak == nil {
                    let sorted = cpu.sorted()
                    let mean = cpu.reduce(0, +) / Double(cpu.count)
                    let p95 = sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
                    rows.append(["state": state, "phase": phase, "renderer": options.renderer,
                                 "cpuMean": mean, "cpuP95": p95, "rssStart": initial.rss, "rssEnd": lastRSS])
                    try writeJSON(rows, to: options.out)
                    print("\(options.renderer) \(state) \(phase): CPU \(String(format: "%.2f", mean))% p95 \(p95)% RSS \(Int(initial.rss))→\(Int(lastRSS)) KiB; \(String(format: "%.1f", fps)) fps")
                }
                fflush(stdout)
            }
        }
    }
}

do {
    let options = try Options()
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let harness = try Harness(options: options)
    try harness.run()
} catch {
    fputs("WeatherPerf: \(error)\n", stderr)
    exit(1)
}
