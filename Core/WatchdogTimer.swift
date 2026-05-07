import Foundation

/// A one-shot-with-reset timer used by wallpaper runtimes to detect
/// unresponsive content.
///
/// Usage:
///   let wd = WatchdogTimer(timeout: 30) { [weak self] in self?.demote() }
///   wd.start()        // starts the countdown
///   wd.heartbeat()    // resets the countdown back to `timeout`
///   wd.stop()         // cancels and releases the closure
///
/// Implementation:
///   Uses a `DispatchSourceTimer` on a private serial queue. `onTimeout` is
///   dispatched to the main queue so callers can safely touch AppKit state.
///   The timer is one-shot; it will fire at most once per `start()`. Callers
///   must either `heartbeat()` before the deadline or accept the trip.
final class WatchdogTimer {

    private let timeout: TimeInterval
    private let onTimeout: () -> Void

    private let queue = DispatchQueue(label: "com.sdelavega.watchdog", qos: .utility)
    private var source: DispatchSourceTimer?
    private var isArmed = false

    /// - Parameters:
    ///   - timeout: seconds of silence before `onTimeout` fires
    ///   - onTimeout: invoked on the main queue when the timer trips
    init(timeout: TimeInterval, onTimeout: @escaping () -> Void) {
        self.timeout = timeout
        self.onTimeout = onTimeout
    }

    deinit {
        isArmed = false
        cancelSourceLocked()
    }

    /// Arms the timer. If already armed, resets the countdown (heartbeat)
    /// instead of allocating a new DispatchSourceTimer.
    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if self.isArmed {
                self.source?.schedule(deadline: .now() + self.timeout)
                return
            }

            let src = DispatchSource.makeTimerSource(queue: self.queue)
            src.schedule(deadline: .now() + self.timeout)
            src.setEventHandler { [weak self] in
                guard let self = self else { return }
                guard self.isArmed else { return }
                self.isArmed = false
                self.source?.cancel()
                self.source = nil
                DispatchQueue.main.async { self.onTimeout() }
            }
            self.source = src
            self.isArmed = true
            src.resume()
        }
    }

    /// Reset the countdown back to the full `timeout`. Safe to call from any
    /// thread. If the timer isn't armed, this is a no-op.
    func heartbeat() {
        queue.async { [weak self] in
            guard let self = self, self.isArmed, let src = self.source else { return }
            src.schedule(deadline: .now() + self.timeout)
        }
    }

    /// Cancels any pending trip. After `stop()` the timer is inert until
    /// `start()` is called again. Uses queue.sync to guarantee the cancel
    /// has taken effect before returning, which prevents spurious timeout
    /// callbacks after a logical stop.
    func stop() {
        queue.sync {
            self.cancelSourceLocked()
        }
    }

    private func cancelSourceLocked() {
        isArmed = false
        source?.cancel()
        source = nil
    }
}
