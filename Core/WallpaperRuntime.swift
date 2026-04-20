import AppKit
import Foundation

/// A single wallpaper instance attached to a single display. Each display
/// may own at most one WallpaperRuntime at a time.
///
/// Lifecycle:
///   init → start() → [pause() / resume() / updateProperty()] → stop()
///
/// Implementations must:
///   - never steal focus
///   - never call AppKit on non-main threads
///   - be resilient to `stop()` being called before `start()` succeeded
///   - degrade gracefully under pause / low-power mode
protocol WallpaperRuntime: AnyObject {
    var displayID: CGDirectDisplayID { get }
    var isPaused: Bool { get }
    var contentView: NSView { get }

    func start() throws
    func pause()
    func resume()
    func stop()
    func reload() throws
    func updateProperty(_ key: String, value: Any)
}

/// Errors produced by wallpaper runtimes during lifecycle operations.
/// The host uses these to decide whether to substitute a fallback / safe-mode
/// wallpaper or to surface an import report entry.
enum WallpaperRuntimeError: Error, CustomStringConvertible {
    case failedToLoad(String)
    case invalidBundle
    case contentNotFound
    case renderingFailed
    case timeout

    var description: String {
        switch self {
        case .failedToLoad(let s): return "Failed to load wallpaper: \(s)"
        case .invalidBundle:       return "Invalid wallpaper bundle"
        case .contentNotFound:     return "Wallpaper content not found"
        case .renderingFailed:     return "Wallpaper rendering failed"
        case .timeout:             return "Wallpaper timed out"
        }
    }
}
