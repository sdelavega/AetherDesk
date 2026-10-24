// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Stephen de la Vega
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

import Foundation

@main
struct V13Handover {
    static func main() {
        do {
            try check()
        } catch {
            FileHandle.standardError.write(Data("v1.3 handover: FAIL — \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func check() throws {
        let zip = URL(fileURLWithPath: CommandLine.arguments[1])
        let extractDir = URL(fileURLWithPath: CommandLine.arguments[2])
        let updater = UpdateManager()
        let fm = FileManager.default

        // Feed local disk size into v1.3's release-asset cap before hashing bytes.
        let attributes = try fm.attributesOfItem(atPath: zip.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw UpdateManager.UpdateError.hashVerificationFailed("Could not read archive size")
        }
        let asset = UpdateManager.GitHubRelease.Asset(
            name: "AetherDesk.zip", browser_download_url: zip.absoluteString, size: size.intValue)
        try updater.handoverVerifySizes(asset: asset)
        try updater.verifySHA256(ofFileAt: zip, againstHashFile: zip.appendingPathExtension("sha256"))
        if let error = updater.handoverExtract(zip: zip, to: extractDir) {
            throw error
        }
        guard let appName = try fm.contentsOfDirectory(atPath: extractDir.path)
            .first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateManager.UpdateError.appBundleNotFound
        }
        let app = extractDir.appendingPathComponent(appName)

        let installedPath = "/Applications/ÆtherDesk.app"
        let expectedTeam: String
        if fm.fileExists(atPath: installedPath) {
            guard let team = updater.teamIdentifier(ofAppAtPath: installedPath) else {
                throw UpdateManager.UpdateError.signatureVerificationFailed(
                    "Could not determine signing identity of installed app")
            }
            expectedTeam = team
            print("Expected team: \(expectedTeam) (installed \(installedPath))")
        } else {
            expectedTeam = "N5PUFD82GV"
            print("Expected team: \(expectedTeam) (literal fallback; installed app absent)")
        }
        let candidateTeam = updater.teamIdentifier(ofAppAtPath: app.path)
        guard candidateTeam == expectedTeam else {
            throw UpdateManager.UpdateError.signatureVerificationFailed(
                "TeamIdentifier mismatch: update team \(candidateTeam ?? "unknown"), expected \(expectedTeam)")
        }

        try updater.handoverVerifyCodeSignature(ofAppAtPath: app.path)
        guard let version = Bundle(url: app)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else {
            throw UpdateManager.UpdateError.signatureVerificationFailed("Missing app version")
        }
        print("v1.3 handover: OK (\(version))")
    }
}
