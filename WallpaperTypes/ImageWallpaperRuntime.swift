import AppKit
import Foundation
import ImageIO

/// Minimal image wallpaper runtime. Shows a single static image at the
/// display size, stretched proportionally. No animation, no network, no JS.
/// Included for completeness so static Lively bundles don't fall back to
/// the web runtime unnecessarily.
final class ImageWallpaperRuntime: NSObject, WallpaperRuntime {

    let displayID: CGDirectDisplayID
    private(set) var isPaused: Bool = false

    private let bundle: WallpaperBundle
    private let imageView: NSImageView

    var contentView: NSView { imageView }

    init(bundle: WallpaperBundle, displayID: CGDirectDisplayID) {
        self.bundle = bundle
        self.displayID = displayID
        self.imageView = NSImageView()
        super.init()

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.black.cgColor
        imageView.autoresizingMask = [.width, .height]
    }

    func start() throws {
        guard let imageURL = bundle.imageURL else {
            throw WallpaperRuntimeError.contentNotFound
        }

        let screen = NSScreen.screens.first(where: { $0.displayID == displayID })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let maxPixel = max(
            Int((screen?.frame.width ?? 1920) * (screen?.backingScaleFactor ?? 2.0)),
            Int((screen?.frame.height ?? 1080) * (screen?.backingScaleFactor ?? 2.0))
        )

        let image: NSImage
        if let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailFromImageAlways: true
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                image = NSImage(cgImage: cgImage, size: screen?.frame.size ?? NSSize(width: 1920, height: 1080))
            } else {
                guard let fallback = NSImage(contentsOf: imageURL) else {
                    throw WallpaperRuntimeError.contentNotFound
                }
                image = fallback
            }
        } else {
            guard let fallback = NSImage(contentsOf: imageURL) else {
                throw WallpaperRuntimeError.contentNotFound
            }
            image = fallback
        }
        imageView.image = image
    }

    func pause()  { isPaused = true }
    func resume() { isPaused = false }

    func stop() {
        imageView.image = nil
    }

    func reload() throws {
        stop()
        try start()
    }

    func updateProperty(_ key: String, value: Any) {
        // Static images have no dynamic properties in v1.
    }
}
