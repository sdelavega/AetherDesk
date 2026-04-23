import AppKit
import Foundation

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
            }
        }
    }

    // MARK: - Properties

    private(set) var state: UpdateState = .idle

    private let session: URLSession
    private let queue = DispatchQueue(label: "com.aetherdesk.UpdateManager", qos: .utility)
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
        guard case .idle = state else { return }
        fetchLatestRelease { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                NSLog("ÆtherDesk UpdateManager: check failed — %@", error.localizedDescription)
                self.state = .idle
            case .success(let release):
                guard self.isNewer(release) else {
                    self.state = .idle
                    return
                }
                let settings = UpdateSettingsStore.shared.load()
                if let skipped = settings.skippedVersion,
                   skipped == self.version(from: release) {
                    NSLog("ÆtherDesk UpdateManager: %@ is available but was skipped by user", release.tag_name)
                    self.state = .idle
                    return
                }
                self.state = .available(release)
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
    func checkForUpdatesInteractively() {
        state = .checking
        fetchLatestRelease { [weak self] result in
            guard let self else { return }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error):
                    self.state = .failed(error)
                    self.presentAlert(
                        style: .warning,
                        title: "Update check failed",
                        body: error.localizedDescription)
                    self.state = .idle
                case .success(let release):
                    if self.isNewer(release) {
                        self.state = .available(release)
                        self.presentUpdateAlert(release)
                    } else {
                        self.state = .idle
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
        guard let asset = release.assets.first(where: { $0.name == Self.assetName }),
              let downloadURL = URL(string: asset.browser_download_url) else {
            DispatchQueue.main.async {
                self.state = .failed(UpdateError.noZipAsset)
                self.presentAlert(style: .warning,
                                  title: "Update failed",
                                  body: UpdateError.noZipAsset.localizedDescription)
                self.state = .idle
            }
            return
        }

        DispatchQueue.main.async { self.state = .downloading }

        session.downloadTask(with: downloadURL) { [weak self] tempURL, _, error in
            guard let self else { return }
            if let error {
                DispatchQueue.main.async {
                    self.state = .failed(UpdateError.downloadFailed(error))
                    self.presentAlert(style: .warning,
                                      title: "Download failed",
                                      body: error.localizedDescription)
                    self.state = .idle
                }
                return
            }
            guard let tempURL else { return }

            // URLSession deletes the file at tempURL as soon as this completion
            // handler returns. Move it to a stable path before we dispatch
            // performInstall to the background queue.
            let stableURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("AetherDesk-dl-\(UUID().uuidString).zip")
            do {
                try FileManager.default.moveItem(at: tempURL, to: stableURL)
            } catch {
                DispatchQueue.main.async {
                    self.state = .failed(UpdateError.downloadFailed(error))
                    self.presentAlert(style: .warning,
                                      title: "Download failed",
                                      body: error.localizedDescription)
                    self.state = .idle
                }
                return
            }
            self.queue.async { self.performInstall(zipURL: stableURL) }
        }.resume()
    }

    // MARK: - Code signature verification

    /// Verifies the downloaded .app has a valid code signature and was signed
    /// by the same identity as the currently running app. Without this check a
    /// MITM'd or compromised download could replace the app with arbitrary code.
    private func verifyCodeSignature(ofAppAtPath appPath: String) throws {
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", appPath]
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

    // MARK: - Shell-script self-replacement

    private func performInstall(zipURL: URL) {
        DispatchQueue.main.async { self.state = .installing }

        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("AetherDesk-Update-\(UUID().uuidString)")

        do { try fm.createDirectory(at: tempDir, withIntermediateDirectories: true) } catch {
            try? fm.removeItem(at: zipURL)
            return reportInstallError(UpdateError.extractionFailed(-1))
        }

        // Move the downloaded zip inside tempDir so the cleanup script's
        // `rm -rf tempDir` removes it along with the extracted contents.
        let zipInTempDir = tempDir.appendingPathComponent("AetherDesk.zip")
        do {
            try fm.moveItem(at: zipURL, to: zipInTempDir)
        } catch {
            try? fm.removeItem(at: zipURL)
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
            try? fm.removeItem(at: tempDir)
            return reportInstallError(error as? UpdateError
                ?? .signatureVerificationFailed(error.localizedDescription))
        }

        // Script waits for this process to die, swaps the .app, relaunches.
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do
            sleep 0.5
        done
        sleep 1
        rm -rf "\(currentAppPath)"
        mv "\(newAppPath)" "\(currentAppPath)"
        rm -rf "\(tempDir.path)"
        open "\(currentAppPath)"
        """

        let scriptURL = tempDir.appendingPathComponent("update.sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            return reportInstallError(UpdateError.scriptLaunchFailed(error))
        }

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = [scriptURL.path]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError  = FileHandle.nullDevice
        do {
            try launcher.run()
        } catch {
            return reportInstallError(UpdateError.scriptLaunchFailed(error))
        }

        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    private func reportInstallError(_ error: UpdateError) {
        DispatchQueue.main.async {
            self.state = .failed(error)
            self.presentAlert(style: .warning,
                              title: "Update failed",
                              body: error.localizedDescription)
            self.state = .idle
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
            state = .idle
        default:
            state = .idle
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
