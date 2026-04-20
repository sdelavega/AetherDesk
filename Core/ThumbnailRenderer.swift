import AppKit
import AVFoundation
import WebKit
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
///   ~/Library/Caches/com.aetherdesk.ÆtherDesk/thumbnails/<bundleID>_<w>x<h>.png
/// keyed by bundle id + requested pixel size. Cache entries older than the
/// source bundle's mtime are invalidated at lookup time.
final class ThumbnailRenderer {

    static let shared = ThumbnailRenderer()

    private let queue = DispatchQueue(label: "com.aetherdesk.thumbnails", qos: .utility)
    private let fileManager = FileManager.default
    private let cacheDir: URL

    /// Holds a strong ref to the per-request offscreen WKWebView / delegate
    /// while it loads. Keyed by the request's UUID.
    private var pendingWebRenders: [UUID: WebRender] = [:]
    private let pendingLock = NSLock()

    /// In-memory cache of bundle directory modification dates to avoid
    /// repeated filesystem stat calls for cache validation.
    private var bundleModDates: [URL: Date] = [:]

    /// Pool of reusable offscreen WKWebViews for thumbnail rendering.
    private var webViewPool: [WKWebView] = []
    private static let maxPoolSize = 2

    init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.cacheDir = caches
            .appendingPathComponent(Constants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("thumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
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
                guard let self = self else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                if let image = image {
                    self.writeCache(image: image, to: cacheURL)
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

        // Target t=1s, clamped to the asset duration.
        let duration = CMTimeGetSeconds(asset.duration)
        let target = CMTime(seconds: min(1.0, max(0.0, duration / 2.0)),
                            preferredTimescale: 600)

        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: target)]) {
            _, cgImage, _, _, _ in
            guard let cgImage = cgImage else {
                completion(nil); return
            }
            let nsImage = NSImage(cgImage: cgImage, size: size)
            completion(nsImage.resized(to: size))
        }
    }

    // MARK: Web thumbnails

    private func renderWebSnapshot(indexURL: URL,
                                   baseURL: URL,
                                   size: NSSize,
                                   completion: @escaping (NSImage?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { completion(nil); return }
            let token = UUID()
            let wv = self.checkoutWebView(size: size)
            let render = WebRender(token: token,
                                   size: size,
                                   webView: wv,
                                   onFinish: { [weak self] image, usedView in
                guard let self = self else { return }
                self.pendingLock.lock()
                self.pendingWebRenders.removeValue(forKey: token)
                self.pendingLock.unlock()
                if let usedView = usedView {
                    self.returnWebView(usedView)
                }
                completion(image)
            })
            self.pendingLock.lock()
            self.pendingWebRenders[token] = render
            self.pendingLock.unlock()
            render.load(indexURL: indexURL, baseURL: baseURL)
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
    /// cropped / letterboxed on a transparent background.
    fileprivate func resized(to target: NSSize) -> NSImage {
        if target.width <= 0 || target.height <= 0 { return self }
        let out = NSImage(size: target)
        out.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: target).fill()

        let source = self.size
        guard source.width > 0, source.height > 0 else {
            out.unlockFocus()
            return out
        }
        let scale = min(target.width / source.width, target.height / source.height)
        let w = source.width * scale
        let h = source.height * scale
        let drawRect = NSRect(x: (target.width - w) / 2,
                              y: (target.height - h) / 2,
                              width: w, height: h)
        self.draw(in: drawRect,
                  from: NSRect(origin: .zero, size: source),
                  operation: .copy,
                  fraction: 1.0)
        out.unlockFocus()
        return out
    }
}
