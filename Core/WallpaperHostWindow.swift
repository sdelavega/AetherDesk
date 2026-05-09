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

    /// The display this host window targets. Set after init via convenience
    /// initializer; defaults to 0 (unused by AppKit).
    private(set) var targetDisplayID: CGDirectDisplayID = 0

    /// Create a host window covering the given screen at the desktop level.
    ///
    /// Declared as a `convenience init` so that NSWindow's designated
    /// initializers are inherited. NSWindow's ObjC init chain internally
    /// re-dispatches `initWithContentRect:styleMask:backing:defer:` to
    /// `self`; if that designated init isn't available, Swift generates a
    /// trap stub that crashes with EXC_BREAKPOINT.
    convenience init(screen: NSScreen) {
        self.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        self.targetDisplayID = screen.displayID
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

    /// Re-apply the desktop window level and ordering. macOS may reset
    /// window ordering after display sleep/wake cycles.
    func reassertDesktopLevel() {
        level = WallpaperHostWindow.desktopLevel
        orderBack(nil)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The AppKit `NSWindow.Level` that sits behind regular app windows
    /// but above the system wallpaper picture.
    private static let desktopLevel: NSWindow.Level = {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
    }()
}
