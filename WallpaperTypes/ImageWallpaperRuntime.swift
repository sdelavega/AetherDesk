import AppKit
import Foundation

class ImageWallpaperRuntime: NSObject, WallpaperRuntime {

    let displayID: CGDirectDisplayID
    private(set) var isPaused: Bool = false

    private let bundle: WallpaperBundle
    private var imageView: NSImageView!

    var contentView: NSView {
        return imageView
    }

    init(bundle: WallpaperBundle, displayID: CGDirectDisplayID) {
        self.bundle = bundle
        self.displayID = displayID
        super.init()

        setupImageView()
    }

    func start() throws {
        guard let imageURL = bundle.imageURL,
              let image = NSImage(contentsOf: imageURL) else {
            throw WallpaperRuntimeError.contentNotFound
        }

        imageView.image = image
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    func stop() {
        imageView.image = nil
    }

    func updateProperty(_ key: String, value: Any) {
        // Image wallpapers don't support property updates in v1
    }

    func reload() throws {
        stop()
        try start()
    }

    private func setupImageView() {
        imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
