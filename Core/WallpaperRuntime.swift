import AppKit
import Foundation

protocol WallpaperRuntime: AnyObject {
    var displayID: CGDirectDisplayID { get }
    var isPaused: Bool { get }
    var contentView: NSView { get }

    func start() throws
    func pause()
    func resume()
    func stop()
    func updateProperty(_ key: String, value: Any)
    func reload() throws
}

enum WallpaperRuntimeError: Error {
    case failedToLoad(String)
    case invalidBundle
    case contentNotFound
    case renderingFailed
    case timeout
}
