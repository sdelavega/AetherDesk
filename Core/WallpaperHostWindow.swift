import AppKit
import Foundation

class WallpaperHostWindow: NSWindow {

    private let targetDisplayID: CGDirectDisplayID

    init(screen: NSScreen) {
        self.targetDisplayID = screen.displayID ?? 0

        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        configureWindow()
    }

    private func configureWindow() {
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.joinsAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        contentView = NSView(frame: self.frame)
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    func setContentView(_ view: NSView) {
        contentView?.addSubview(view)
        view.frame = contentView?.bounds ?? .zero
        view.autoresizingMask = [.width, .height]
    }

    func enableInteraction() {
        ignoresMouseEvents = false
        level = .floating
    }

    func disableInteraction() {
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    }

    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}
