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
import AVFoundation
import WebKit
import ImageIO
import Foundation

/// Generates preview thumbnails for wallpaper bundles.
///
/// Source priority:
///   1. Bundle-provided preview image (Lively convention: preview.gif /
///      preview.jpg / preview.png, or whatever `LivelyInfo.Preview` points to).
///      Handled via `WallpaperBundle.previewImageURL`.
///   2. Type-specific render:
///      - `.image` → the image itself
///      - `.video` → `AVAssetImageGenerator` grabs a frame at t≈1s
///      - `.web`   → an offscreen WKWebView loads `index.html`, waits a
///                   short "settle" delay, then `takeSnapshot(with:)`
///   3. On failure → nil (callers should show a placeholder)
///
/// All results are disk-cached under
///   ~/Library/Caches/com.sdelavega.ÆtherDesk/thumbnails/<bundleID>_<w>x<h>.png
/// keyed by bundle id + requested pixel size. Cache entries older than the
/// source bundle's mtime are invalidated at lookup time.
final class ThumbnailRenderer {

    static let shared = ThumbnailRenderer()

    private let queue = DispatchQueue(label: "com.sdelavega.thumbnails", qos: .utility)
    private let fileManager = FileManager.default
    private let cacheDir: URL

    /// Holds a strong ref to the per-request offscreen WKWebView / delegate
    /// while it loads. Keyed by the request's UUID.
    private var pendingWebRenders: [UUID: WebRender] = [:]

    /// In-memory cache of bundle directory modification dates to avoid
    /// repeated filesystem stat calls for cache validation.
    private var bundleModDates: [URL: Date] = [:]

    /// Pool of reusable offscreen WKWebViews for thumbnail rendering.
    private var webViewPool: [WKWebView] = []
    private static let maxPoolSize = 2

    /// Renders waiting to start because `maxConcurrentWebRenders` is saturated.
    private var webRenderQueue: [WebRenderRequest] = []
    private static let maxConcurrentWebRenders = 3

    init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDir = caches
            .appendingPathComponent(Constants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        pruneOrphanedCache()
    }

    /// Remove cached thumbnails whose bundle no longer exists. Called once
    /// at init so orphaned entries don't accumulate indefinitely.
    func pruneOrphanedCache() {
        let validIDs = Set(WallpaperImporter.shared.listWallpapers().map { $0.id.uuidString })
        guard let entries = try? fileManager.contentsOfDirectory(atPath: cacheDir.path) else { return }
        for entry in entries {
            // Filename format: <bundleUUID>_<w>x<h>.png
            let prefix = entry.components(separatedBy: "_").first ?? entry
            if !validIDs.contains(prefix) {
                let url = cacheDir.appendingPathComponent(entry)
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Asynchronously produces an NSImage of the requested pixel size for
    /// `bundle`. `completion` is always invoked on the main thread.
    func thumbnail(for bundle: WallpaperBundle,
                   size: NSSize,
                   completion: @escaping (NSImage?) -> Void) {
        let cacheURL = cachePath(for: bundle.id, size: size)

        queue.async { [weak self] in
            guard let self = self else { return }

            // Serve from cache if still valid.
            if let cached = self.loadCached(url: cacheURL, bundleURL: bundle.baseURL) {
                DispatchQueue.main.async { completion(cached) }
                return
            }

            // Fresh render.
            self.render(bundle: bundle, size: size) { [weak self] image in
                if let image = image, let self = self {
                    self.queue.async {
                        self.writeCache(image: image, to: cacheURL)
                    }
                }
                DispatchQueue.main.async { completion(image) }
            }
        }
    }

    // MARK: Cache

    private func cachePath(for bundleID: UUID, size: NSSize) -> URL {
        let w = Int(size.width)
        let h = Int(size.height)
        return cacheDir.appendingPathComponent("\(bundleID.uuidString)_\(w)x\(h).png")
    }

    /// Returns a cached image if (a) it exists and (b) its mtime is newer
    /// than the source bundle's mtime. Otherwise nil.
    private func loadCached(url: URL, bundleURL: URL) -> NSImage? {
        guard fileManager.fileExists(atPath: url.path),
              let cachedAttrs = try? fileManager.attributesOfItem(atPath: url.path),
              let cachedDate = cachedAttrs[.modificationDate] as? Date
        else { return nil }

        if let sourceDate = bundleModificationDate(at: bundleURL),
           sourceDate > cachedDate {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    /// Shallow mtime probe of the bundle directory. Good enough for cache
    /// invalidation; we don't recursively walk. Results are cached in memory
    /// for the session to avoid repeated stat calls.
    private func bundleModificationDate(at url: URL) -> Date? {
        if let cached = bundleModDates[url] { return cached }
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        let date = attrs[.modificationDate] as? Date
        if let date = date { bundleModDates[url] = date }
        return date
    }

    func invalidateModificationDateCache() {
        bundleModDates.removeAll()
    }

    private func writeCache(image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url, options: .atomic)
    }

    // MARK: Render pipeline

    private func render(bundle: WallpaperBundle,
                        size: NSSize,
                        completion: @escaping (NSImage?) -> Void) {
        // 1. Lively-style preview image.
        if let preview = bundle.previewImageURL,
           let image = loadAndResize(url: preview, to: size) {
            completion(image)
            return
        }

        // 2. Type-specific render.
        switch bundle.type {
        case .image:
            if let img = bundle.imageURL.flatMap({ loadAndResize(url: $0, to: size) }) {
                completion(img); return
            }
            completion(nil)

        case .video:
            guard let url = bundle.videoURL else { completion(nil); return }
            renderVideoFrame(url: url, size: size, completion: completion)

        case .web:
            guard let url = bundle.indexURL else { completion(nil); return }
            renderWebSnapshot(indexURL: url, baseURL: bundle.baseURL, size: size, completion: completion)

        case .unknown:
            completion(nil)
        }
    }

    private func loadAndResize(url: URL, to size: NSSize) -> NSImage? {
        // Ask ImageIO to decode at thumbnail resolution rather than loading the
        // full-size image into memory first. For an imported 4K wallpaper image
        // decoded to an 88×48-pt thumbnail this is ~100× fewer pixels to decode.
        // The max-pixel-size is 2× the largest logical dimension to cover Retina.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxPixels = Int(max(size.width, size.height) * 2)
        let opts: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) {
            return NSImage(cgImage: cg, size: size).resized(to: size)
        }
        // Fallback: formats ImageIO cannot thumbnail (e.g. animated WebP).
        guard let image = NSImage(contentsOf: url) else { return nil }
        return image.resized(to: size)
    }

    // MARK: Video thumbnails

    private func renderVideoFrame(url: URL, size: NSSize,
                                  completion: @escaping (NSImage?) -> Void) {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)

        Task {
            do {
                let cmDuration = try await asset.load(.duration)
                let duration = CMTimeGetSeconds(cmDuration)
                let target = CMTime(seconds: min(1.0, max(0.0, duration / 2.0)),
                                    preferredTimescale: 600)
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: target)]) {
                    _, cgImage, _, _, _ in
                    guard let cgImage = cgImage else { completion(nil); return }
                    let nsImage = NSImage(cgImage: cgImage, size: size)
                    completion(nsImage.resized(to: size))
                }
            } catch {
                completion(nil)
            }
        }
    }

    // MARK: Web thumbnails

    private func renderWebSnapshot(indexURL: URL,
                                   baseURL: URL,
                                   size: NSSize,
                                   completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { completion(nil); return }
            if self.pendingWebRenders.count >= Self.maxConcurrentWebRenders {
                // Defer until a slot opens up.
                self.webRenderQueue.append(
                    WebRenderRequest(indexURL: indexURL, baseURL: baseURL,
                                     size: size, completion: completion))
                return
            }
            self.startWebRender(indexURL: indexURL, baseURL: baseURL,
                                size: size, completion: completion)
        }
    }

    private func startWebRender(indexURL: URL, baseURL: URL, size: NSSize,
                                completion: @escaping (NSImage?) -> Void) {
        let token = UUID()
        let wv = checkoutWebView(size: size)
        let render = WebRender(token: token, size: size, webView: wv,
                               onFinish: { [weak self] image, usedView in
            guard let self = self else { return }
            self.pendingWebRenders.removeValue(forKey: token)
            if let usedView = usedView { self.returnWebView(usedView) }
            completion(image)
            self.drainWebRenderQueue()
        })
        pendingWebRenders[token] = render
        render.load(indexURL: indexURL, baseURL: baseURL)
    }

    /// Start queued renders whenever a concurrent slot opens up. Always called
    /// on the main queue (from the onFinish completion path).
    private func drainWebRenderQueue() {
        while !webRenderQueue.isEmpty {
            guard pendingWebRenders.count < Self.maxConcurrentWebRenders else { break }
            let next = webRenderQueue.removeFirst()
            startWebRender(indexURL: next.indexURL, baseURL: next.baseURL,
                           size: next.size, completion: next.completion)
        }
    }

    // MARK: WebView pool

    private func checkoutWebView(size: NSSize) -> WKWebView {
        if let wv = webViewPool.popLast() {
            wv.frame = NSRect(x: 0, y: 0,
                              width: max(size.width, 320),
                              height: max(size.height, 180))
            return wv
        }
        let frame = NSRect(x: 0, y: 0,
                           width: max(size.width, 320),
                           height: max(size.height, 180))
        let config = WKWebViewConfiguration()
        // Block ads, trackers, and miners in thumbnail WebViews consistent
        // with the live runtime. The external-network block is intentionally
        // omitted here: applying it would make thumbnails for wallpapers that
        // load CDN assets render blank, which would be misleading in the picker.
        let userContent = WKUserContentController()
        if let ruleList = ContentRuleListManager.shared.ruleList {
            userContent.add(ruleList)
        }
        config.userContentController = userContent
        let wv = WKWebView(frame: frame, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.wantsLayer = true
        return wv
    }

    private func returnWebView(_ wv: WKWebView) {
        wv.stopLoading()
        wv.navigationDelegate = nil
        wv.loadHTMLString("", baseURL: nil)
        if webViewPool.count < Self.maxPoolSize {
            webViewPool.append(wv)
        }
    }
}

// MARK: - WebRenderRequest

private struct WebRenderRequest {
    let indexURL: URL
    let baseURL: URL
    let size: NSSize
    let completion: (NSImage?) -> Void
}

// MARK: - WebRender (one-shot offscreen WKWebView snapshot)

/// Owns the offscreen WKWebView for a single snapshot request and keeps
/// itself alive via `ThumbnailRenderer.pendingWebRenders` until either the
/// snapshot completes or a hard timeout fires.
private final class WebRender: NSObject, WKNavigationDelegate {
    let token: UUID
    let size: NSSize
    let onFinish: (NSImage?, WKWebView?) -> Void

    private var webView: WKWebView?
    private var didFinish = false
    private var timeoutWork: DispatchWorkItem?

    /// Seconds to wait after `didFinish` before snapshotting. Gives
    /// setup code in the page a chance to lay out.
    private static let settleDelay: TimeInterval = 0.6

    /// Hard cap: if the page never loads, give up and return nil.
    private static let hardTimeout: TimeInterval = 8.0

    init(token: UUID, size: NSSize, webView: WKWebView,
         onFinish: @escaping (NSImage?, WKWebView?) -> Void) {
        self.token = token
        self.size = size
        self.webView = webView
        self.onFinish = onFinish
        super.init()
    }

    func load(indexURL: URL, baseURL: URL) {
        guard let wv = webView else { onFinish(nil, nil); return }
        wv.navigationDelegate = self
        wv.loadFileURL(indexURL, allowingReadAccessTo: baseURL)

        // Hard timeout so we never leak the offscreen view forever.
        let work = DispatchWorkItem { [weak self] in
            self?.finish(nil)
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hardTimeout, execute: work)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            self?.takeSnapshot()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func takeSnapshot() {
        guard let wv = webView, !didFinish else { return }
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        wv.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self = self else { return }
            if let image = image {
                self.finish(image.resized(to: self.size))
            } else {
                self.finish(nil)
            }
        }
    }

    private func finish(_ image: NSImage?) {
        guard !didFinish else { return }
        didFinish = true
        timeoutWork?.cancel()
        timeoutWork = nil
        let wv = webView
        webView = nil
        onFinish(image, wv)
    }
}

// MARK: - NSImage resize helper

extension NSImage {
    /// Scale this image to the given size preserving aspect ratio, center
    /// cropped / letterboxed on a transparent background. Uses CGContext
    /// instead of lockFocus so it's safe to call from background threads.
    fileprivate func resized(to target: NSSize) -> NSImage {
        if target.width <= 0 || target.height <= 0 { return self }
        let source = self.size
        guard source.width > 0, source.height > 0 else {
            return NSImage(size: target)
        }

        let pixelW = Int(target.width * 2)
        let pixelH = Int(target.height * 2)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0) else {
            return self
        }
        rep.size = target

        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return self }
        let cgCtx = ctx.cgContext
        cgCtx.clear(CGRect(origin: .zero, size: CGSize(width: pixelW, height: pixelH)))

        let scale = min(target.width / source.width, target.height / source.height)
        let w = source.width * scale
        let h = source.height * scale
        let drawRect = NSRect(x: (target.width - w) / 2,
                              y: (target.height - h) / 2,
                              width: w, height: h)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        self.draw(in: drawRect,
                  from: NSRect(origin: .zero, size: source),
                  operation: .copy,
                  fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: target)
        out.addRepresentation(rep)
        return out
    }
}
