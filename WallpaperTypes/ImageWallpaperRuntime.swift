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
        isPaused = false
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
        let screenSize = screen?.frame.size ?? NSSize(width: 1920, height: 1080)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let image = Self.loadImage(at: imageURL, maxPixel: maxPixel, screenSize: screenSize)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isPaused else { return }
                self.imageView.image = image
            }
        }
    }

    private static func loadImage(at url: URL, maxPixel: Int, screenSize: NSSize) -> NSImage? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceCreateThumbnailFromImageAlways: true
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return NSImage(cgImage: cgImage, size: screenSize)
            }
        }
        return NSImage(contentsOf: url)
    }

    func pause()  { isPaused = true }
    func resume() { isPaused = false }

    func stop() {
        isPaused = true
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
