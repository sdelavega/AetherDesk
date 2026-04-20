import AppKit
import Foundation

/// A borderless, non-activating NSWindow that sits at the desktop layer
/// (behind regular application windows but in front of the system wallpaper
/// picture) and hosts one wallpaper runtime's content view.
///
/// Design notes:
///  - `.desktopWindow` level places the window behind app windows.
///  - `.canJoinAllSpaces` + `.stationary` + `.ignoresCycle` keep the host
///    on every Space and stop it from participating in Cmd-` / Mission
///    Control cycling.
///  - Mouse events are ignored by default. `enableInteraction()` is only
///    used for a debug / interaction mode (not part of the normal user flow).
///  - `canBecomeKey` / `canBecomeMain` are overridden to `false` so the
///    window never steals focus — important for a wallpaper host.
final class WallpaperHostWindow: NSWindow {

    let targetDisplayID: CGDirectDisplayID

    init(screen: NSScreen) {
        self.targetDisplayID = screen.displayID

        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )

        configureWindow()
    }

    private func configureWindow() {
        level = WallpaperHostWindow.desktopLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .none

        let root = NSView(frame: frame)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        root.autoresizingMask = [.width, .height]
        contentView = root
    }

    /// Install a wallpaper runtime's content view as the current wallpaper.
    /// Removes any previously installed runtime view.
    func setContentView(_ view: NSView) {
        contentView?.subviews.forEach { $0.removeFromSuperview() }
        view.frame = contentView?.bounds ?? .zero
        view.autoresizingMask = [.width, .height]
        contentView?.addSubview(view)
    }

    /// Optional debug / interaction mode. NOT used during normal wallpaper
    /// display; only useful for developer-only debugging of HTML wallpapers.
    func enableInteraction() {
        ignoresMouseEvents = false
        level = .floating
    }

    func disableInteraction() {
        ignoresMouseEvents = true
        level = WallpaperHostWindow.desktopLevel
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The AppKit `NSWindow.Level` that sits behind regular app windows
    /// but above the system wallpaper picture.
    private static let desktopLevel: NSWindow.Level = {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    }()
}
