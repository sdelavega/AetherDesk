import Foundation

class WallpaperValidator {

    struct ValidationResult {
        let classification: WallpaperClassification
        let warnings: [String]
        let issues: [String]
    }

    func validate(at url: URL) -> WallpaperClassification {
        var warnings: [String] = []
        var issues: [String] = []

        if let jsWarnings = checkJavaScript(at: url) {
            warnings.append(contentsOf: jsWarnings.warnings)
            issues.append(contentsOf: jsWarnings.issues)
        }

        if let fileIssue = checkFileSize(at: url) {
            warnings.append(fileIssue)
        }

        if let networkIssue = checkNetworkUsage(at: url) {
            issues.append(networkIssue)
        }

        if !issues.isEmpty {
            let reason = issues.joined(separator: "; ")
            return .rejected(reason: reason)
        }

        if !warnings.isEmpty {
            return .allowedWithLimits(fps: 30, networkBudget: 5)
        }

        return .allowed
    }

    private func checkJavaScript(at url: URL) -> (warnings: [String], issues: [String])? {
        var warnings: [String] = []
        var issues: [String] = []

        let indexURL = url.appendingPathComponent(Constants.Keys.indexFile)
        guard let jsContent = try? String(contentsOf: indexURL, encoding: .utf8) else {
            return nil
        }

        if jsContent.contains("eval(") {
            warnings.append("JavaScript contains eval() usage which may indicate dynamic code execution")
        }

        let timerPattern = "setInterval"
        let matches = jsContent.components(separatedBy: timerPattern)
        if matches.count > 2 {
            warnings.append("Multiple setInterval calls detected - animation may be intensive")
        }

        if jsContent.contains("fetch(") || jsContent.contains("XMLHttpRequest") {
            if jsContent.contains("setInterval") && matches.count > 3 {
                issues.append("Network requests combined with frequent timers detected")
            }
        }

        let suspiciousPatterns = [
            "document.write",
            "innerHTML =",
            "outerHTML =",
            "eval(",
            "Function(",
            "crypto.",
            "WebAssembly"
        ]

        for pattern in suspiciousPatterns {
            if jsContent.contains(pattern) {
                warnings.append("Contains \(pattern) which may indicate potentially problematic code")
            }
        }

        return (warnings, issues)
    }

    private func checkFileSize(at url: URL) -> String? {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }

        var totalSize: Int64 = 0

        while let fileURL = enumerator.nextObject() as? URL {
            if let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(fileSize)
            }
        }

        let maxSize = 50 * 1024 * 1024

        if totalSize > maxSize {
            return "Bundle size exceeds \(maxSize / 1024 / 1024)MB limit"
        }

        return nil
    }

    private func checkNetworkUsage(at url: URL) -> String? {
        let indexURL = url.appendingPathComponent(Constants.Keys.indexFile)
        guard let jsContent = try? String(contentsOf: indexURL, encoding: .utf8) else {
            return nil
        }

        let networkCalls = (jsContent.components(separatedBy: "fetch(").count - 1) +
                           (jsContent.components(separatedBy: "XMLHttpRequest").count - 1) +
                           (jsContent.components(separatedBy: "axios").count - 1)

        if networkCalls > 10 {
            return "Excessive network calls (\(networkCalls)) detected"
        }

        if jsContent.contains("while") && jsContent.contains("fetch(") {
            return "Potential infinite network loop detected"
        }

        return nil
    }

    private var fileManager: FileManager {
        return FileManager.default
    }
}
