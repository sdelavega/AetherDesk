import AppKit
import AVFoundation

class VideoWallpaperRuntime: NSObject, WallpaperRuntime {

    let displayID: CGDirectDisplayID
    private(set) var isPaused: Bool = false

    private let bundle: WallpaperBundle
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private let hostingView = NSView()

    var contentView: NSView { hostingView }

    init(bundle: WallpaperBundle, displayID: CGDirectDisplayID) {
        self.bundle = bundle
        self.displayID = displayID
        super.init()
        setupPlayerLayer()
    }

    func start() throws {
        guard let url = bundle.videoURL else {
            throw WallpaperRuntimeError.contentNotFound
        }
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        self.player = player
        playerLayer?.player = player

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(loopVideo(_:)),
                                               name: .AVPlayerItemDidPlayToEndTime,
                                               object: item)
        player.play()
    }

    func pause() {
        isPaused = true
        player?.pause()
    }

    func resume() {
        isPaused = false
        player?.play()
    }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    func reload() throws {
        stop()
        try start()
    }

    func updateProperty(_ key: String, value: Any) {
        // No-op for now; video wallpapers typically have no dynamic properties.
    }

    private func setupPlayerLayer() {
        hostingView.wantsLayer = true
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        hostingView.layer = layer
        playerLayer = layer
    }

    @objc private func loopVideo(_ notification: Notification) {
        if let item = notification.object as? AVPlayerItem {
            item.seek(to: .zero, completionHandler: nil)
        }
    }
}

enum WallpaperRuntimeError: Error {
    case contentNotFound
}
