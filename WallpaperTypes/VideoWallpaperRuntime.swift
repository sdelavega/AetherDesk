import AppKit
import AVKit
import AVFoundation
import Foundation

class VideoWallpaperRuntime: NSObject, WallpaperRuntime {

    let displayID: CGDirectDisplayID
    private(set) var isPaused: Bool = false

    private let bundle: WallpaperBundle
    private var playerView: AVPlayerView!
    private var player: AVPlayer!
    private var playerItem: AVPlayerItem!

    var contentView: NSView {
        return playerView
    }

    init(bundle: WallpaperBundle, displayID: CGDirectDisplayID) {
        self.bundle = bundle
        self.displayID = displayID
        super.init()

        setupPlayer()
    }

    func start() throws {
        guard let videoURL = bundle.videoURL else {
            throw WallpaperRuntimeError.contentNotFound
        }

        playerItem = AVPlayerItem(url: videoURL)
        if player == nil {
            player = AVPlayer(playerItem: playerItem)
            playerView.player = player
        } else {
            player.replaceCurrentItem(with: playerItem)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidReachEnd),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
    }

    func pause() {
        isPaused = true
        player.pause()
    }

    func resume() {
        isPaused = false
        player.play()
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func updateProperty(_ key: String, value: Any) {
        // Video wallpapers don't support property updates in v1
    }

    func reload() throws {
        stop()
        try start()
    }

    private func setupPlayer() {
        playerView = AVPlayerView()
        player = AVPlayer()
        playerView.player = player
        // Hide playback controls for wallpaper usage on macOS
        playerView.controlsStyle = .none
        playerView.isHidden = false
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    @objc private func playerDidReachEnd(_ notification: Notification) {
        player.seek(to: .zero)
        player.play()
    }
}
