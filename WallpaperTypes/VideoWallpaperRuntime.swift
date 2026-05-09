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
import os.log
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
    private let pausedSnapshotView: NSImageView
    private var pausedTime: CMTime?

    private var endObserver:    NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?

    var contentView: NSView { playerView }

    init(bundle: WallpaperBundle, displayID: CGDirectDisplayID) {
        self.bundle = bundle
        self.displayID = displayID
        self.player = AVPlayer()
        self.playerView = AVPlayerView()
        self.pausedSnapshotView = NSImageView()
        super.init()

        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = true

        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspectFill
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor

        pausedSnapshotView.translatesAutoresizingMaskIntoConstraints = false
        pausedSnapshotView.imageScaling = .scaleAxesIndependently
        pausedSnapshotView.imageAlignment = .alignCenter
        pausedSnapshotView.isHidden = true
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

        removePausedSnapshot()
        if !isPaused { player.play() }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        pausedTime = player.currentTime()
        capturePausedFrame()
        player.pause()
        removeObservers()
        removePlayerItem()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        do {
            try start()
            if let pausedTime {
                player.seek(to: pausedTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
            player.play()
        } catch {
            reportFailure(reason: "resume failed: \(error)")
        }
    }

    func stop() {
        removeObservers()
        pausedTime = nil
        removePausedSnapshot()
        player.pause()
        removePlayerItem()
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
        Logger.app.error("ÆtherDesk: video runtime failure on display \(self.displayID): \(reason)")
        NotificationCenter.default.post(
            name: Constants.Notifications.runtimeDidFail,
            object: nil,
            userInfo: ["displayID": displayID, "reason": reason])
    }

    private func capturePausedFrame() {
        guard let videoURL = bundle.videoURL else { return }
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: max(playerView.bounds.width, 1),
                                       height: max(playerView.bounds.height, 1))
        let targetTime = pausedTime ?? .zero

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let image: NSImage? = {
                guard let cgImage = try? generator.copyCGImage(at: targetTime, actualTime: nil) else { return nil }
                return NSImage(cgImage: cgImage, size: self.playerView.bounds.size)
            }()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isPaused, let image else { return }
                self.installPausedSnapshot(image)
            }
        }
    }

    private func installPausedSnapshot(_ image: NSImage) {
        pausedSnapshotView.image = image
        if pausedSnapshotView.superview == nil {
            playerView.addSubview(pausedSnapshotView)
            NSLayoutConstraint.activate([
                pausedSnapshotView.topAnchor.constraint(equalTo: playerView.topAnchor),
                pausedSnapshotView.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
                pausedSnapshotView.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
                pausedSnapshotView.trailingAnchor.constraint(equalTo: playerView.trailingAnchor)
            ])
        }
        pausedSnapshotView.isHidden = false
    }

    private func removePausedSnapshot() {
        pausedSnapshotView.isHidden = true
        pausedSnapshotView.image = nil
    }

    private func removePlayerItem() {
        player.replaceCurrentItem(with: nil)
        playerItem = nil
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
