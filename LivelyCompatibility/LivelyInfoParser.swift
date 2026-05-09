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

import Foundation

struct LivelyInfo: Decodable {
    let AppVersion: String?
    let Version: Int?
    let Title: String?
    let Description: String?
    let Author: String?
    let Homepage: String?
    let type: String?
    let FileName: String?
    let Arguments: Arguments?
    let Environment: Environment?
    let IsAbsolutePath: Bool?
    let SteamFileID: String?
    let WorkshopID: String?
    let ContentImage: [String]?
    let Preview: String?
    let License: String?
    let SupportType: String?
    let Manifest: [String]?
    let Tags: [String]?
    let ReleaseDate: String?
    let EmbededResources: [String]?

    private enum CodingKeys: String, CodingKey {
        case AppVersion
        case Version
        case Title
        case Description
        case Author
        case Homepage
        case type = "Type"
        case FileName
        case Arguments
        case Environment
        case IsAbsolutePath
        case SteamFileID
        case WorkshopID
        case ContentImage
        case Preview
        case License
        case SupportType
        case Manifest
        case Tags
        case ReleaseDate
        case EmbededResources
        case Desc
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        AppVersion = try container.decodeIfPresent(String.self, forKey: .AppVersion)
        Version = try container.decodeIfPresent(Int.self, forKey: .Version)
        Title = try container.decodeIfPresent(String.self, forKey: .Title)
        Author = try container.decodeIfPresent(String.self, forKey: .Author)
        Homepage = try container.decodeIfPresent(String.self, forKey: .Homepage)
        FileName = try container.decodeIfPresent(String.self, forKey: .FileName)
        self.Environment = try container.decodeIfPresent(Self.Environment.self, forKey: .Environment)
        IsAbsolutePath = try container.decodeIfPresent(Bool.self, forKey: .IsAbsolutePath)
        SteamFileID = try container.decodeIfPresent(String.self, forKey: .SteamFileID)
        WorkshopID = try container.decodeIfPresent(String.self, forKey: .WorkshopID)
        ContentImage = try container.decodeIfPresent([String].self, forKey: .ContentImage)
        Preview = try container.decodeIfPresent(String.self, forKey: .Preview)
        License = try container.decodeIfPresent(String.self, forKey: .License)
        SupportType = try container.decodeIfPresent(String.self, forKey: .SupportType)
        Manifest = try container.decodeIfPresent([String].self, forKey: .Manifest)
        Tags = try container.decodeIfPresent([String].self, forKey: .Tags)
        ReleaseDate = try container.decodeIfPresent(String.self, forKey: .ReleaseDate)
        EmbededResources = try container.decodeIfPresent([String].self, forKey: .EmbededResources)

        // Handle Description vs Desc (both used by Lively wallpapers)
        if container.contains(.Description) {
            Description = try container.decodeIfPresent(String.self, forKey: .Description)
        } else {
            Description = try container.decodeIfPresent(String.self, forKey: .Desc)
        }

        // Handle Arguments: may be struct or plain string in some wallpapers
        self.Arguments = (try? container.decodeIfPresent(Self.Arguments.self, forKey: .Arguments)) ?? nil

        // Handle Type as string ("web") or int (Lively convention: 1=web, 2=video, 3=app)
        if let stringType = try? container.decode(String.self, forKey: .type) {
            type = stringType
        } else if let intType = try? container.decode(Int.self, forKey: .type) {
            switch intType {
            case 1: type = "web"
            case 2: type = "video"
            case 3: type = "app"
            default: type = String(intType)
            }
        } else {
            type = nil
        }
    }

    struct Arguments: Decodable {
        let version: Int?
        let file: String?
        let arguments: String?
    }

    struct Environment: Decodable {
        let variable: String?
        let data: String?
    }
}

class LivelyInfoParser {

    private static var cache: [URL: (mtime: Date, info: LivelyInfo)] = [:]
    private static let lock = NSLock()

    func parse(from url: URL) -> LivelyInfo? {
        let livelyInfoURL = url.appendingPathComponent(Constants.Keys.livelyInfo)

        guard FileManager.default.fileExists(atPath: livelyInfoURL.path) else {
            return nil
        }

        // Check cache keyed by file URL + modification time.
        let attrs = try? FileManager.default.attributesOfItem(atPath: livelyInfoURL.path)
        let mtime = attrs?[.modificationDate] as? Date

        Self.lock.lock()
        if let cached = Self.cache[livelyInfoURL], mtime == nil || cached.mtime == mtime {
            Self.lock.unlock()
            return cached.info
        }
        Self.lock.unlock()

        do {
            let data = try Data(contentsOf: livelyInfoURL)
            let decoder = JSONDecoder()
            let info = try decoder.decode(LivelyInfo.self, from: data)
            Self.lock.lock()
            Self.cache[livelyInfoURL] = (mtime: mtime ?? Date(), info: info)
            Self.lock.unlock()
            return info
        } catch {
            print("ÆtherDesk: Failed to parse LivelyInfo.json: \(error)")
            return nil
        }
    }

    func parse(from data: Data) -> LivelyInfo? {
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(LivelyInfo.self, from: data)
        } catch {
            print("ÆtherDesk: Failed to parse LivelyInfo: \(error)")
            return nil
        }
    }
}
