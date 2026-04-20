import AppKit
import AVKit
import AVFoundation
import Foundation

/// AVFoundation-backed video wallpaper runtime. Loops muted video at
/// the wallpaper host's bounds. Accepts mp4 / mov / m4v / webm
/// (via VideoToolbox where supported).
///
/// Failure signalling:
///   Observes `AVPlayerItemFailedToPlayToEndTime`, `AVPlayerItemNewErrorLogEntry`
///   with fatal status, and KVO on the item's `status` / `error`. On a
///   hard failure we post `runtimeDidFail` so the manager can demote the
///   display to safe content.
final class VideoWallpaperRuntime: NSObject, WallpaperRuntime {

    let displayID: CGDirectDisplayID
    private(set) var isPaused: Bool = false

    private let bundle: WallpaperBundle
    private let playerView: AVPlayerView
    private let player: AVPlayer
    private var playerItem: AVPlayerItem?

    private var endObserver:    NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

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
        removeObservers()
    }

    func start() throws {
        guard let videoURL = bundle.videoURL else {
            throw WallpaperRuntimeError.contentNotFound
        }

        let item = AVPlayerItem(url: videoURL)
        playerItem = item
        player.replaceCurrentItem(with: item)

        removeObservers()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.handleItemDidReachEnd()
        }

        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "failed to play to end"
            self?.reportFailure(reason: "AVPlayer: \(reason)")
        }

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .failed {
                let reason = item.error?.localizedDescription ?? "AVPlayerItem failed"
                DispatchQueue.main.async { self?.reportFailure(reason: reason) }
            }
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
        removeObservers()
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

    // MARK: Internals

    private func handleItemDidReachEnd() {
        player.seek(to: .zero)
        if !isPaused { player.play() }
    }

    private func reportFailure(reason: String) {
        NSLog("ÆtherDesk: video runtime failure on display %u: %@", displayID, reason)
        NotificationCenter.default.post(
            name: Constants.Notifications.runtimeDidFail,
            object: nil,
            userInfo: ["displayID": displayID, "reason": reason])
    }

    private func removeObservers() {
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        if let obs = failedObserver {
            NotificationCenter.default.removeObserver(obs)
            failedObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
    }
}
