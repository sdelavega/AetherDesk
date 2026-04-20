import AppKit
import AVKit
import AVFoundation
import Foundation

/// AVFoundation-backed video wallpaper runtime. Loops muted video at
/// the wallpaper host's bounds. Accepts mp4 / mov / m4v / webm
/// (via VideoToolbox where supported).
final class VideoWallpaperRuntime: NSObject, WallpaperRuntime {

    let displayID: CGDirectDisplayID
    private(set) var isPaused: Bool = false

    private let bundle: WallpaperBundle
    private let playerView: AVPlayerView
    private let player: AVPlayer
    private var playerItem: AVPlayerItem?
    private var endObserver: NSObjectProtocol?

    var contentView: NSView { playerView }

    init(bundle: WallpaperBundle, displayID: CGDirectDisplayID) {
        self.bundle = bundle
        self.displayID = displayID
        self.player = AVPlayer()
        self.playerView = AVPlayerView()
        super.init()

        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true

        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspectFill
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor
    }

    deinit {
        removeEndObserver()
    }

    func start() throws {
        guard let videoURL = bundle.videoURL else {
            throw WallpaperRuntimeError.contentNotFound
        }

        let item = AVPlayerItem(url: videoURL)
        playerItem = item
        player.replaceCurrentItem(with: item)

        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleItemDidReachEnd()
        }

        if !isPaused { player.play() }
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
        removeEndObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
        playerItem = nil
    }

    func reload() throws {
        stop()
        try start()
    }

    func updateProperty(_ key: String, value: Any) {
        // v1: video wallpapers don't expose properties to the JS bridge.
        // Allow a documented `volume` override for debugging.
        if key == "volume", let v = value as? Double {
            player.volume = Float(max(0.0, min(1.0, v)))
        }
    }

    private func handleItemDidReachEnd() {
        player.seek(to: .zero)
        if !isPaused { player.play() }
    }

    private func removeEndObserver() {
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
    }
}
