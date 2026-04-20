import Foundation

struct LivelyProperty: Codable {
    let name: String
    let description: String?
    let `type`: String
    let value: AnyCodableValue
    let min: AnyCodableValue?
    let max: AnyCodableValue?
    let increment: Double?
    let items: [AnyCodableValue]?
    let isExpanded: Bool?
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case description = "Description"
        case type = "Type"
        case value = "Value"
        case min = "Min"
        case max = "Max"
        case increment = "Increment"
        case items = "Items"
        case isExpanded = "IsExpanded"
        case readOnly = "ReadOnly"
    }
}

struct LivelyProperties: Codable {
    let properties: [LivelyProperty]
}

enum PropertyType: String {
    case range = "range"
    case bool = "bool"
    case checkbox = "checkbox"
    case choice = "choice"
    case dropdown = "dropdown"
    case color = "color"
    case text = "text"
    case unknown

    init(from string: String) {
        let normalized = string.lowercased()
        switch normalized {
        case "slider": self = .range
        default: self = PropertyType(rawValue: normalized) ?? .unknown
        }
    }
}

class LivelyPropertiesParser {

    func parse(from url: URL) -> [LivelyProperty]? {
        let propertiesURL = url.appendingPathComponent(Constants.Keys.livelyProperties)

        guard FileManager.default.fileExists(atPath: propertiesURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: propertiesURL)
            return parse(from: data)
        } catch {
            print("AetherDesk: Failed to parse LivelyProperties.json: \(error)")
            return nil
        }
    }

    func parse(from data: Data) -> [LivelyProperty]? {
        // Try array format first: { "properties": [...] }
        if let properties = try? JSONDecoder().decode(LivelyProperties.self, from: data) {
            return properties.properties
        }

        // Try per-key format: { "propName": { "type": "slider", ... } }
        return parsePerKeyFormat(from: data)
    }

    private func parsePerKeyFormat(from data: Data) -> [LivelyProperty]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var propertiesArray: [[String: Any]] = []
        for (key, value) in json {
            guard let dict = value as? [String: Any] else { continue }
            var mapped: [String: Any] = ["Name": key]
            if let type = dict["type"] as? String { mapped["Type"] = type }
            if let val = dict["value"] { mapped["Value"] = val }
            if let min = dict["min"] { mapped["Min"] = min }
            if let max = dict["max"] { mapped["Max"] = max }
            if let step = dict["step"] { mapped["Increment"] = step }
            if let text = dict["text"] as? String { mapped["Description"] = text }
            propertiesArray.append(mapped)
        }

        guard !propertiesArray.isEmpty else { return nil }
        let wrapped: [String: Any] = ["properties": propertiesArray]
        guard let reencoded = try? JSONSerialization.data(withJSONObject: wrapped) else { return nil }
        return try? JSONDecoder().decode(LivelyProperties.self, from: reencoded).properties
    }
}

struct AnyCodableValue: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let intValue = try? container.decode(Int.self) {
            value = intValue
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = stringValue
        } else if let boolValue = try? container.decode(Bool.self) {
            value = boolValue
        } else if let arrayValue = try? container.decode([AnyCodableValue].self) {
            value = arrayValue.map { $0.value }
        } else if let dictValue = try? container.decode([String: AnyCodableValue].self) {
            value = dictValue.mapValues { $0.value }
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let intValue as Int:
            try container.encode(intValue)
        case let doubleValue as Double:
            try container.encode(doubleValue)
        case let stringValue as String:
            try container.encode(stringValue)
        case let boolValue as Bool:
            try container.encode(boolValue)
        case let arrayValue as [Any]:
            try container.encode(arrayValue.map { AnyCodableValue($0) })
        case let dictValue as [String: Any]:
            try container.encode(dictValue.mapValues { AnyCodableValue($0) })
        default:
            try container.encode(String(describing: value))
        }
    }

    var intValue: Int? {
        return value as? Int
    }

    var doubleValue: Double? {
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        return nil
    }

    var stringValue: String? {
        return value as? String
    }

    var boolValue: Bool? {
        return value as? Bool
    }
}
