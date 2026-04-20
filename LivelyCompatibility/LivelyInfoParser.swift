import Foundation

struct LivelyInfo: Codable {
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
    }

    struct Arguments: Codable {
        let version: Int?
        let file: String?
        let arguments: String?
    }

    struct Environment: Codable {
        let variable: String?
        let data: String?
    }
}

class LivelyInfoParser {

    func parse(from url: URL) -> LivelyInfo? {
        let livelyInfoURL = url.appendingPathComponent(Constants.Keys.livelyInfo)

        guard FileManager.default.fileExists(atPath: livelyInfoURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: livelyInfoURL)
            let decoder = JSONDecoder()
            return try decoder.decode(LivelyInfo.self, from: data)
        } catch {
            print("AetherDesk: Failed to parse LivelyInfo.json: \(error)")
            return nil
        }
    }

    func parse(from data: Data) -> LivelyInfo? {
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(LivelyInfo.self, from: data)
        } catch {
            print("AetherDesk: Failed to parse LivelyInfo: \(error)")
            return nil
        }
    }
}
