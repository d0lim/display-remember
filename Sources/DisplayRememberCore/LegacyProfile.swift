import Foundation

/// Imports the legacy version 1 profile format without permissive numeric coercion.
public enum LegacyProfileImporter {
    public static func read(data: Data, name: String) throws -> DisplayProfile {
        let legacy = try JSONDecoder().decode(LegacyProfile.self, from: data)
        guard legacy.version == 1 else {
            throw DisplayRememberError("Unsupported legacy profile version; expected version 1.")
        }
        let displays = try legacy.displays.enumerated().map { index, display in
            ProfileDisplay(key: "display-\(index + 1)", label: display.label,
                match: try ProfileValidation.selector(display.match.selector),
                settings: try display.settings.converted())
        }
        let profile = DisplayProfile(name: name, displays: displays)
        _ = try ProfileValidation.profile(profile)
        return profile
    }
}

private struct LegacyProfile: Decodable {
    let version: Int
    let displays: [LegacyDisplay]

    enum CodingKeys: String, CodingKey, CaseIterable { case version, displays }

    init(from decoder: Decoder) throws {
        let values = try strictContainer(decoder, keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        displays = try values.decode([LegacyDisplay].self, forKey: .displays)
    }
}

private struct LegacyDisplay: Decodable {
    let label: String
    let match: LegacySelector
    let settings: LegacySettings

    enum CodingKeys: String, CodingKey, CaseIterable { case label, match, settings }

    init(from decoder: Decoder) throws {
        let values = try strictContainer(decoder, keyedBy: CodingKeys.self)
        label = try values.decode(String.self, forKey: .label)
        match = try values.decode(LegacySelector.self, forKey: .match)
        settings = try values.decode(LegacySettings.self, forKey: .settings)
    }
}

private struct LegacySelector: Decodable {
    let selector: DisplaySelector

    enum CodingKeys: String, CodingKey, CaseIterable {
        case vendor, product, builtin
        case serialText = "serial_text"
        case serialNumber = "serial_number"
        case edidSHA256 = "edid_sha256"
    }

    init(from decoder: Decoder) throws {
        let values = try strictContainer(decoder, keyedBy: CodingKeys.self)
        selector = DisplaySelector(
            vendor: try values.decodeWhenPresent(UInt32.self, forKey: .vendor),
            product: try values.decodeWhenPresent(UInt32.self, forKey: .product),
            serialText: try values.decodeWhenPresent(String.self, forKey: .serialText),
            serialNumber: try values.decodeWhenPresent(UInt32.self, forKey: .serialNumber),
            edidSHA256: try values.decodeWhenPresent(String.self, forKey: .edidSHA256),
            builtin: try values.decodeWhenPresent(Bool.self, forKey: .builtin)
        )
    }
}

private struct LegacySettings: Decodable {
    let resolution: String
    let refreshRate: Int?
    let colorDepth: Int
    let scaling: String
    let origin: [Int]
    let degree: Int
    let enabled: Bool

    enum CodingKeys: String, CodingKey, CaseIterable {
        case resolution = "res"
        case refreshRate = "hz"
        case colorDepth = "color_depth"
        case scaling, origin, degree, enabled
    }

    init(from decoder: Decoder) throws {
        let values = try strictContainer(decoder, keyedBy: CodingKeys.self)
        resolution = try values.decode(String.self, forKey: .resolution)
        refreshRate = try values.decodeWhenPresent(Int.self, forKey: .refreshRate)
        colorDepth = try values.decode(Int.self, forKey: .colorDepth)
        scaling = try values.decode(String.self, forKey: .scaling)
        origin = try values.decode([Int].self, forKey: .origin)
        degree = try values.decode(Int.self, forKey: .degree)
        enabled = try values.decode(Bool.self, forKey: .enabled)
    }

    func converted() throws -> DisplaySettings {
        let dimensions = resolution.split(separator: "x", omittingEmptySubsequences: false)
        guard dimensions.count == 2, dimensions.allSatisfy({ dimension in
            guard let first = dimension.utf8.first, (49...57).contains(first) else { return false }
            return dimension.utf8.allSatisfy { (48...57).contains($0) }
        }), let width = Int(dimensions[0]), let height = Int(dimensions[1]) else {
            throw DisplayRememberError("Legacy resolution must contain positive WIDTHxHEIGHT dimensions.")
        }
        guard origin.count == 2 else {
            throw DisplayRememberError("Legacy display origin must contain exactly two integers.")
        }
        guard scaling == "on" || scaling == "off" else {
            throw DisplayRememberError("Legacy scaling must be 'on' or 'off'.")
        }
        return DisplaySettings(width: width, height: height, refreshRate: refreshRate,
            colorDepth: colorDepth, scaled: scaling == "on", x: origin[0], y: origin[1],
            rotation: degree, enabled: enabled)
    }
}

private struct LegacyField: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func strictContainer<Key: CodingKey & CaseIterable>(
    _ decoder: Decoder, keyedBy type: Key.Type
) throws -> KeyedDecodingContainer<Key> {
    let keys = try decoder.container(keyedBy: LegacyField.self).allKeys
    let allowed = Set(Key.allCases.map(\.stringValue))
    if let unknown = keys.first(where: { !allowed.contains($0.stringValue) }) {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
            debugDescription: "Unknown legacy profile field: \(unknown.stringValue)"))
    }
    return try decoder.container(keyedBy: type)
}

private extension KeyedDecodingContainer {
    /// Missing optional fields are allowed; present null or wrongly typed fields are not.
    func decodeWhenPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        contains(key) ? try decode(type, forKey: key) : nil
    }
}
