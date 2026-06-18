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
import Foundation
import CryptoKit

// The entire self-update mechanism — periodic GitHub Releases polling,
// downloading, code-signature verification, and the atomic app-bundle
// swap-and-relaunch — is excluded from App Store builds. Apple Guideline
// 2.4.5(vii) prohibits apps from updating themselves outside the Mac App
// Store, and review has flagged this before. App Store builds get updates
// through the Mac App Store exclusively; none of this code should even be
// compiled into that binary.
#if !AETHERDESK_STORE

/// Checks GitHub Releases for a newer version of ÆtherDesk and, depending on
/// user preferences, either notifies or silently downloads and installs it.
///
/// Lifecycle: call `startPeriodicChecks()` once from AppDelegate after launch.
/// The interactive "Check for Updates…" menu action calls
/// `checkForUpdatesInteractively()`.
final class UpdateManager {

    static let shared = UpdateManager()

    // MARK: - Types

    struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String
        let assets: [Asset]

        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int
        }
    }

    enum UpdateState {
        case idle
        case checking
        case available(GitHubRelease)
        case downloading
        case installing
        case failed(Error)
    }

    enum UpdateError: Error, LocalizedError {
        case noZipAsset
        case downloadFailed(Error)
        case extractionFailed(Int32)
        case appBundleNotFound
        case signatureVerificationFailed(String)
        case scriptLaunchFailed(Error)
        case hashVerificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .noZipAsset:
                return "The release does not contain AetherDesk.zip."
            case .downloadFailed(let e):
                return "Download failed: \(e.localizedDescription)"
            case .extractionFailed(let code):
                return "Extraction failed (ditto exit \(code))."
            case .appBundleNotFound:
                return "Could not locate .app bundle in the downloaded archive."
            case .signatureVerificationFailed(let reason):
                return "Update rejected — signature verification failed: \(reason)"
            case .scriptLaunchFailed(let e):
                return "Could not launch the update installer: \(e.localizedDescription)"
            case .hashVerificationFailed(let reason):
                return "Update rejected — archive integrity check failed: \(reason)"
            }
        }
    }

    // MARK: - Properties

    private(set) var state: UpdateState = .idle {
        didSet { /* mutations funnel through setState(_:) */ }
    }
    private let stateLock = NSLock()

    /// Thread-safe state write. Call this instead of assigning `state` directly.
    private func setState(_ newState: UpdateState) {
        stateLock.lock()
        state = newState
        stateLock.unlock()
    }

    /// Thread-safe state read.
    private var currentState: UpdateState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    private let session: URLSession
    private let queue = DispatchQueue(label: "com.sdelavega.UpdateManager", qos: .utility)
    private var checkTimer: DispatchSourceTimer?

    private static let apiURL = URL(string:
        "https://api.github.com/repos/sdelavega/AetherDesk/releases/latest")!
    private static let assetName = "AetherDesk.zip"

    // MARK: - Init

    private init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["User-Agent": "AetherDesk-Updater"]
        session = URLSession(configuration: config)
    }

    // MARK: - Lifecycle

    /// Start periodic automatic checks. Call once from AppDelegate at launch.
    /// (This whole class is compiled out of App Store builds — see the
    /// `#if !AETHERDESK_STORE` at the top of this file.)
    func startPeriodicChecks() {
        guard UpdateSettingsStore.shared.load().automaticallyCheckForUpdates else { return }
        queue.asyncAfter(deadline: .now() + Constants.Defaults.updateCheckInitialDelay) { [weak self] in
            self?.checkQuietly()
        }
        armTimer()
    }

    /// Restart or cancel the timer when the user toggles the auto-check setting.
    func updateTimerForSettingsChange() {
        if UpdateSettingsStore.shared.load().automaticallyCheckForUpdates {
            armTimer()
        } else {
            checkTimer?.cancel()
            checkTimer = nil
        }
    }

    private func armTimer() {
        checkTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Constants.Defaults.updateCheckInterval,
                       repeating: Constants.Defaults.updateCheckInterval)
        timer.setEventHandler { [weak self] in self?.checkQuietly() }
        timer.resume()
        checkTimer = timer
    }

    // MARK: - Check (quiet)

    private func checkQuietly() {
        guard case .idle = currentState else { return }
        fetchLatestRelease { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                Logger.app.error("ÆtherDesk UpdateManager: check failed — \(error.localizedDescription)")
                self.setState(.idle)
            case .success(let release):
                guard self.isNewer(release) else {
                    self.setState(.idle)
                    return
                }
                let settings = UpdateSettingsStore.shared.load()
                if let skipped = settings.skippedVersion,
                   skipped == self.version(from: release) {
                    Logger.app.info("ÆtherDesk UpdateManager: \(release.tag_name) is available but was skipped by user")
                    self.setState(.idle)
                    return
                }
                self.setState(.available(release))
                if settings.automaticallyInstallUpdates {
                    self.queue.async { self.downloadAndInstall(release) }
                } else {
                    DispatchQueue.main.async {
                        NotificationCenter.default.post(
                            name: Constants.Notifications.updateAvailable,
                            object: release)
                    }
                }
            }
        }
    }

    // MARK: - Check (interactive)

    /// Called from the "Check for Updates…" menu item. Always shows UI feedback.
    /// (This whole class is compiled out of App Store builds — see the
    /// `#if !AETHERDESK_STORE` at the top of this file.)
    func checkForUpdatesInteractively() {
        setState(.checking)
        fetchLatestRelease { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.setState(.failed(error))
                    self.presentAlert(
                        style: .warning,
                        title: "Update check failed",
                        body: error.localizedDescription)
                    self.setState(.idle)
                case .success(let release):
                    if self.isNewer(release) {
                        self.setState(.available(release))
                        self.presentUpdateAlert(release)
                    } else {
                        self.setState(.idle)
                        self.presentAlert(
                            style: .informational,
                            title: "You're up to date",
                            body: "ÆtherDesk \(self.currentVersion()) is the latest version.")
                    }
                }
            }
        }
    }

    // MARK: - Network

    private func fetchLatestRelease(completion: @escaping (Result<GitHubRelease, Error>) -> Void) {
        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let data,
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            do {
                completion(.success(try JSONDecoder().decode(GitHubRelease.self, from: data)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    // MARK: - Version helpers

    func version(from release: GitHubRelease) -> String {
        let tag = release.tag_name
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func isNewer(_ release: GitHubRelease) -> Bool {
        SemanticVersion.compare(version(from: release), isGreaterThan: currentVersion())
    }

    // MARK: - Download + install

    func downloadAndInstall(_ release: GitHubRelease) {
        // Re-entrancy guard: a quiet auto-install can race with a user-triggered
        // install. Only proceed from idle or available states.
        guard case .idle = currentState else { return }
        guard let asset = release.assets.first(where: { $0.name == Self.assetName }),
              let downloadURL = URL(string: asset.browser_download_url) else {
            DispatchQueue.main.async {
                self.setState(.failed(UpdateError.noZipAsset))
                self.presentAlert(style: .warning,
                                  title: "Update failed",
                                  body: UpdateError.noZipAsset.localizedDescription)
                self.setState(.idle)
            }
            return
        }

        // Hard cap before we ever read a response body or disk bytes.
        guard asset.size <= Constants.Defaults.maxUpdateArchiveBytes else {
            DispatchQueue.main.async {
                let reason = "Update archive exceeds the maximum allowed size."
                self.setState(.failed(UpdateError.hashVerificationFailed(reason)))
                self.presentAlert(style: .warning, title: "Update failed", body: reason)
                self.setState(.idle)
            }
            return
        }

        DispatchQueue.main.async { self.setState(.downloading) }

        // Download both the zip and the .sha256 sidecar (if present).
        let group = DispatchGroup()
        var zipTempURL: URL?
        var hashTempURL: URL?
        var downloadError: Error?

        group.enter()
        session.downloadTask(with: downloadURL) { url, _, error in
            zipTempURL = url
            downloadError = downloadError ?? error
            group.leave()
        }.resume()

        let hashURL = downloadURL.appendingPathExtension("sha256")
        group.enter()
        session.downloadTask(with: hashURL) { url, response, error in
            hashTempURL = url
            // 404 for the sidecar is fine — we'll skip hash verification.
            // Any other error (timeout, DNS failure, 500) must fail the update.
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    hashTempURL = nil
                } else if httpResponse.statusCode >= 400 {
                    downloadError = downloadError
                        ?? UpdateError.hashVerificationFailed(
                            "Hash sidecar returned HTTP \(httpResponse.statusCode)")
                }
            } else if error != nil {
                downloadError = downloadError
                    ?? UpdateError.hashVerificationFailed(
                        "Hash sidecar download failed: \(error!.localizedDescription)")
            }
            group.leave()
        }.resume()

        group.notify(queue: self.queue) { [weak self] in
            guard let self else { return }
            if let error = downloadError {
                DispatchQueue.main.async {
                    self.setState(.failed(UpdateError.downloadFailed(error)))
                    self.presentAlert(style: .warning,
                                      title: "Download failed",
                                      body: error.localizedDescription)
                    self.setState(.idle)
                }
                return
            }
            guard let zipTemp = zipTempURL else { return }

            let fm = FileManager.default
            let stableZip = fm.temporaryDirectory
                .appendingPathComponent("AetherDesk-dl-\(UUID().uuidString).zip")
            let stableHash = hashTempURL.flatMap { _ in
                fm.temporaryDirectory
                    .appendingPathComponent("AetherDesk-dl-\(UUID().uuidString).sha256")
            }

            do {
                try fm.moveItem(at: zipTemp, to: stableZip)
                if let hashTemp = hashTempURL, let stableHash = stableHash {
                    try fm.moveItem(at: hashTemp, to: stableHash)
                }
            } catch {
                DispatchQueue.main.async {
                    self.setState(.failed(UpdateError.downloadFailed(error)))
                    self.presentAlert(style: .warning,
                                      title: "Download failed",
                                      body: error.localizedDescription)
                    self.setState(.idle)
                }
                return
            }

            self.performInstall(zipURL: stableZip, hashURL: stableHash)
        }
    }

    // MARK: - Code signature verification

    /// Verifies the downloaded .app has a valid code signature and was signed
    /// by the same identity as the currently running app. Without this check a
    /// MITM'd or compromised download could replace the app with arbitrary code.
    private func verifyCodeSignature(ofAppAtPath appPath: String) throws {
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", appPath]
        verify.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        verify.standardError = errPipe

        do {
            try verify.run()
            verify.waitUntilExit()
        } catch {
            throw UpdateError.signatureVerificationFailed(
                "Could not run codesign: \(error.localizedDescription)")
        }

        guard verify.terminationStatus == 0 else {
            let output = (try? errPipe.fileHandleForReading.readToEnd())
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? "unknown error"
            throw UpdateError.signatureVerificationFailed(
                "Invalid code signature: \(output.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))")
        }

        guard let currentTeamID = teamIdentifier(ofAppAtPath: Bundle.main.bundlePath),
              let newTeamID = teamIdentifier(ofAppAtPath: appPath) else {
            throw UpdateError.signatureVerificationFailed(
                "Could not determine signing identity of current or downloaded app")
        }

        guard currentTeamID == newTeamID else {
            throw UpdateError.signatureVerificationFailed(
                "Signing identity mismatch: update was signed by a different developer (team \(newTeamID), expected \(currentTeamID))")
        }

        // Adhoc-signed builds accept any adhoc-signed update. Log a warning
        // for dev builds; reject in App Store / release builds.
        if currentTeamID == "adhoc" {
            #if AETHERDESK_STORE
            throw UpdateError.signatureVerificationFailed(
                "Adhoc-signed updates are not allowed in release builds")
            #else
            Logger.app.warning("ÆtherDesk: accepting adhoc-signed update in dev build")
            #endif
        }
    }

    /// Extracts the TeamIdentifier from `codesign -dvvv` output, which
    /// identifies the Apple Developer team regardless of whether the cert
    /// is "Developer ID Application" or "Apple Development".
    private func teamIdentifier(ofAppAtPath appPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dvvv", appPath]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = try? pipe.fileHandleForReading.readToEnd()
            let output = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""

            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("TeamIdentifier=") {
                    let teamID = line.dropFirst("TeamIdentifier=".count)
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    return teamID.isEmpty ? nil : teamID
                }
            }

            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("Authority=") {
                    let authority = line.dropFirst("Authority=".count)
                        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                    if authority.lowercased() == "adhoc" { return "adhoc" }
                    return authority
                }
            }

            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Pure-Swift self-replacement

    private func performInstall(zipURL: URL, hashURL: URL?) {
        DispatchQueue.main.async { self.setState(.installing) }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("AetherDesk-Update-\(UUID().uuidString)")

        // On error paths, clean up tempDir and the downloaded zip immediately.
        // On the success path the updater subprocess owns tempDir — it contains
        // newAppPath and will remove it after the swap. Setting cleanupTempDir
        // to false before the function returns prevents the defer from deleting
        // the new bundle while the subprocess is still waiting to move it.
        // hashURL lives outside tempDir and is always cleaned up unconditionally.
        var cleanupTempDir = true
        defer {
            if cleanupTempDir {
                try? fm.removeItem(at: tempDir)
                try? fm.removeItem(at: zipURL)
            }
            if let hashURL = hashURL {
                try? fm.removeItem(at: hashURL)
            }
        }

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return reportInstallError(UpdateError.extractionFailed(-1))
        }

        // Verify zip hash before extraction, if a sidecar was published.
        if let hashURL = hashURL {
            do {
                try verifySHA256(ofFileAt: zipURL, againstHashFile: hashURL)
            } catch {
                return reportInstallError(error as? UpdateError
                    ?? .hashVerificationFailed(error.localizedDescription))
            }
        }

        let zipInTempDir = tempDir.appendingPathComponent("AetherDesk.zip")
        do {
            try fm.moveItem(at: zipURL, to: zipInTempDir)
        } catch {
            return reportInstallError(UpdateError.extractionFailed(-1))
        }

        let extractDir = tempDir.appendingPathComponent("extracted")

        // ditto preserves code signatures, extended attributes, and notarization tickets.
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-xk", zipInTempDir.path, extractDir.path]
        do { try ditto.run(); ditto.waitUntilExit() } catch {
            return reportInstallError(UpdateError.extractionFailed(-1))
        }
        guard ditto.terminationStatus == 0 else {
            return reportInstallError(UpdateError.extractionFailed(ditto.terminationStatus))
        }

        // Find the .app in the extracted contents.
        guard let appName = (try? fm.contentsOfDirectory(atPath: extractDir.path))?
                .first(where: { $0.hasSuffix(".app") }) else {
            return reportInstallError(UpdateError.appBundleNotFound)
        }

        let newAppPath     = extractDir.appendingPathComponent(appName).path
        let currentAppPath = Bundle.main.bundlePath
        let pid            = ProcessInfo.processInfo.processIdentifier

        do {
            try verifyCodeSignature(ofAppAtPath: newAppPath)
        } catch {
            return reportInstallError(error as? UpdateError
                ?? .signatureVerificationFailed(error.localizedDescription))
        }

        // Relaunch ourselves in updater mode so the swap happens from a
        // separate process after this one exits. No shell scripts involved.
        let currentExecutable = Bundle.main.executableURL?.path ?? currentAppPath
        let updater = Process()
        updater.executableURL = URL(fileURLWithPath: currentExecutable)
        updater.arguments = ["--aetherdesk-updater", String(pid), currentAppPath, newAppPath, tempDir.path]
        updater.standardOutput = FileHandle.nullDevice
        // Redirect stderr to a log file so swap failure diagnostics survive.
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AetherDesk-updater-\(pid).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            updater.standardError = logHandle
        } else {
            updater.standardError = FileHandle.nullDevice
        }
        do {
            try updater.run()
        } catch {
            return reportInstallError(.scriptLaunchFailed(error))
        }

        // Hand off tempDir ownership to the subprocess; the defer must not
        // delete it when performInstall() returns on this success path.
        cleanupTempDir = false

        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    // MARK: - Hash verification

    private func verifySHA256(ofFileAt fileURL: URL, againstHashFile hashURL: URL) throws {
        guard let expectedHash = try? String(contentsOf: hashURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .first,
              !expectedHash.isEmpty else {
            throw UpdateError.hashVerificationFailed("Could not read expected hash from sidecar file")
        }

        guard let computed = try? computeSHA256(ofFileAt: fileURL) else {
            throw UpdateError.hashVerificationFailed("Could not read downloaded archive")
        }

        guard computed.compare(expectedHash, options: .caseInsensitive) == .orderedSame else {
            throw UpdateError.hashVerificationFailed("Hash mismatch: expected \(expectedHash), got \(computed)")
        }
    }

    @available(macOS 12.0, *)
    private func computeSHA256(ofFileAt fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func reportInstallError(_ error: UpdateError) {
        DispatchQueue.main.async {
            self.setState(.failed(error))
            self.presentAlert(style: .warning,
                              title: "Update failed",
                              body: error.localizedDescription)
            self.setState(.idle)
        }
    }

    // MARK: - Alert presentation

    /// Presents `release` as an Install / Skip / Later alert.
    func presentUpdateAlert(_ release: GitHubRelease) {
        let ver = version(from: release)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "ÆtherDesk \(ver) is available"
        alert.informativeText = "You are running version \(currentVersion()). Would you like to install the update?"
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Skip This Version")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            queue.async { self.downloadAndInstall(release) }
        case .alertSecondButtonReturn:
            var settings = UpdateSettingsStore.shared.load()
            settings.skippedVersion = ver
            UpdateSettingsStore.shared.save(settings)
            setState(.idle)
        default:
            setState(.idle)
        }
    }

    private func presentAlert(style: NSAlert.Style, title: String, body: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - SHA-256 helper

private func computeSHA256(ofFileAt fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = CryptoKit.SHA256()
    while true {
        guard let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

#endif // !AETHERDESK_STORE
