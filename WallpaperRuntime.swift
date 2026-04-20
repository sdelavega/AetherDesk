import AppKit

protocol WallpaperRuntime {
    var contentView: NSView { get }
    var displayID: CGDirectDisplayID { get }
    var isPaused: Bool { get }

    func start() throws
    func pause()
    func resume()
    func stop()
    func reload() throws
    func updateProperty(_ key: String, value: Any)
}
