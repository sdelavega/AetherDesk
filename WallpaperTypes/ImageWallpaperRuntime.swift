import AppKit
import Foundation

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
        guard let imageURL = bundle.imageURL,
              let image = NSImage(contentsOf: imageURL) else {
            throw WallpaperRuntimeError.contentNotFound
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
