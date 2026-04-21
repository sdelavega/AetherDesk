import Foundation

/// Screens a candidate wallpaper bundle and classifies it as:
///   .allowed                  – safe to run without constraints
///   .allowedWithLimits(...)   – run but clamp FPS and cap network use
///   .rejected(reason:)        – do not import (produces a human-readable reason)
///
/// Prompt requirement: treat import validation as a first-class feature,
/// not an afterthought. We produce a detailed report with warnings and
/// hard issues and reject bundles that look like resource hogs or like
/// they want to behave as foreground apps.
final class WallpaperValidator {

    struct Report: CustomStringConvertible {
        let classification: WallpaperClassification
        let warnings: [String]
        let issues: [String]
        let totalBundleBytes: Int64
        let indexJSLength: Int

        var description: String {
            var lines: [String] = []
            switch classification {
            case .allowed:
                lines.append("Allowed.")
            case .allowedWithLimits(let fps, let budget, _):
                lines.append("Allowed with limits. FPS cap: \(fps), network budget: \(budget) req/min.")
            case .rejected(let reason):
                lines.append("Rejected: \(reason)")
            }
            lines.append("Size: \(totalBundleBytes / 1024) KB, JS: \(indexJSLength) chars")
            if !warnings.isEmpty {
                lines.append("Warnings:")
                warnings.forEach { lines.append("  - \($0)") }
            }
            if !issues.isEmpty {
                lines.append("Issues:")
                issues.forEach { lines.append("  - \($0)") }
            }
            return lines.joined(separator: "\n")
        }
    }

    // Tuning knobs.
    private let maxBundleBytes: Int64 = 50 * 1024 * 1024   // 50 MB
    private let defaultFPSLimit = Constants.Defaults.fpsCap
    private let defaultNetworkBudget = 5                    // requests / minute

    func validate(at url: URL) -> WallpaperClassification {
        report(at: url).classification
    }

    func report(at url: URL) -> Report {
        var warnings: [String] = []
        var issues: [String] = []

        let totalSize = bundleSize(at: url)
        if totalSize > maxBundleBytes {
            issues.append("Bundle size \(totalSize / 1024 / 1024) MB exceeds \(maxBundleBytes / 1024 / 1024) MB limit")
        }

        let indexURL = url.appendingPathComponent(Constants.Keys.indexFile)
        let js = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""

        if !js.isEmpty {
            inspectJavaScript(js, warnings: &warnings, issues: &issues)
        }

        if let info = LivelyInfoParser().parse(from: url), let typeString = info.type?.lowercased() {
            if typeString == "application" {
                issues.append("Executable wallpapers are not supported on macOS")
            }
            if typeString == "unity" || typeString == "godot" {
                issues.append("\(typeString) wallpapers require platform-specific runtime not supported on macOS")
            }
        }

        let classification: WallpaperClassification
        if !issues.isEmpty {
            classification = .rejected(reason: issues.joined(separator: "; "))
        } else if !warnings.isEmpty {
            classification = .allowedWithLimits(fps: defaultFPSLimit,
                                                networkBudget: defaultNetworkBudget,
                                                warnings: warnings)
        } else {
            classification = .allowed
        }

        return Report(classification: classification,
                      warnings: warnings,
                      issues: issues,
                      totalBundleBytes: totalSize,
                      indexJSLength: js.count)
    }

    // MARK: Heuristics

    private func inspectJavaScript(_ js: String,
                                   warnings: inout [String],
                                   issues: inout [String]) {
        let setIntervalCount = count(of: "setInterval", in: js)
        if setIntervalCount > 3 {
            warnings.append("Uses setInterval \(setIntervalCount) times — possible timer storm")
        }

        let fetchCount = count(of: "fetch(", in: js) + count(of: "XMLHttpRequest", in: js)
        if fetchCount > 10 {
            issues.append("Excessive network call sites (\(fetchCount)) — exceeds budget")
        } else if fetchCount > 0 {
            warnings.append("Performs network requests (\(fetchCount) call sites) — will be rate-limited")
        }

        if js.contains("while(true)") || js.contains("while (true)") {
            issues.append("Contains infinite while(true) loop")
        }

        if js.contains("navigator.geolocation") {
            warnings.append("Requests geolocation")
        }
        if js.contains("Notification.requestPermission") {
            warnings.append("Requests system notification permission")
        }

        // Tracker / ad domains → hard reject
        let trackers = ["googletagmanager", "google-analytics",
                        "doubleclick", "facebook.net"]
        for pattern in trackers {
            if js.contains(pattern) {
                issues.append("References \(pattern) (tracker/ad script)")
            }
        }

        // Suspicious but non-fatal JS patterns → warn + limit
        let suspicious = ["document.write(", "eval(", "Function(",
                          "WebAssembly"]
        for pattern in suspicious {
            if js.contains(pattern) {
                warnings.append("Uses \(pattern)")
            }
        }

        // ── GPU / rendering resource checks ──────────────────────────────

        // shadowBlur is the single most expensive Canvas 2D operation.
        // A few instances are fine; many usually means every-frame glow
        // effects that hammer the GPU (the old NeonCity pattern).
        let shadowBlurCount = count(of: "shadowBlur", in: js)
        if shadowBlurCount > 5 {
            warnings.append("Heavy GPU shadow usage (\(shadowBlurCount) shadowBlur calls) — may drain battery")
        }

        // Composite blend modes (screen, overlay, multiply, etc.) are
        // expensive when layered repeatedly per frame.
        let compositeCount = count(of: "globalCompositeOperation", in: js)
        if compositeCount > 5 {
            warnings.append("Heavy composite blending (\(compositeCount) mode switches)")
        }

        // WebGL is legitimate but GPU-intensive; flag so the user knows.
        if js.contains("getContext('webgl")
            || js.contains("getContext(\"webgl")
            || js.contains("getContext(`webgl") {
            warnings.append("Uses WebGL (GPU-intensive)")
        }

        // Very large script payloads are a code-smell for bloated or
        // bundled applications rather than lightweight wallpapers.
        if js.count > 500_000 {
            warnings.append("Large script payload (\(js.count / 1024) KB)")
        }

        // ── Hard rejects: patterns that have no place in a wallpaper ─────

        let miners = ["coinhive", "CoinHive", "cryptonight", "CryptoMiner",
                       "minero", "hashrate", "stratum+tcp"]
        for pattern in miners {
            if js.contains(pattern) {
                issues.append("Contains crypto mining code (\(pattern))")
            }
        }

        if js.contains("navigator.serviceWorker") {
            issues.append("Registers a ServiceWorker (not appropriate for wallpapers)")
        }
        if js.contains("SharedWorker") {
            issues.append("Uses SharedWorker (not appropriate for wallpapers)")
        }
        if js.contains("window.open(") || js.contains("window.open (") {
            issues.append("Attempts to open browser windows")
        }
    }

    private func bundleSize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func count(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        return haystack.components(separatedBy: needle).count - 1
    }
}
