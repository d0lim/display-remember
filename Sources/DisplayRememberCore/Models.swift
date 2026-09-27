import Foundation

public struct DisplayRememberError: LocalizedError, Codable, Hashable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct HardwareIdentity: Codable, Hashable, Sendable {
    public var vendor: UInt32
    public var product: UInt32
    public var serialText: String
    public var serialNumber: UInt32
    public var edidSHA256: String?
    public var builtin: Bool

    public init(vendor: UInt32, product: UInt32, serialText: String = "",
                serialNumber: UInt32 = 0, edidSHA256: String? = nil, builtin: Bool = false) {
        self.vendor = vendor
        self.product = product
        self.serialText = serialText
        self.serialNumber = serialNumber
        self.edidSHA256 = edidSHA256
        self.builtin = builtin
    }

    public static func normalizedSerialText(_ value: String) -> String {
        let serial = value.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\0")))
        let lower = serial.lowercased()
        let placeholders: Set<String> = ["unknown", "none", "null", "n/a", "na", "default",
            "unspecified", "not specified", "not available", "serial", "serial number", "serialnumber"]
        let compact = lower.filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }
        if placeholders.contains(lower) || compact.isEmpty || compact.allSatisfy({ $0 == "0" })
            || compact.allSatisfy({ $0 == "f" }) { return "" }
        return serial
    }
}

public struct DisplaySettings: Codable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var refreshRate: Int?
    public var colorDepth: Int
    public var scaled: Bool
    public var x: Int
    public var y: Int
    public var rotation: Int
    public var enabled: Bool
    public var modeNumber: Int?
    public var quiet: Bool

    public init(width: Int, height: Int, refreshRate: Int? = nil, colorDepth: Int = 8,
                scaled: Bool = false, x: Int = 0, y: Int = 0, rotation: Int = 0,
                enabled: Bool = true, modeNumber: Int? = nil, quiet: Bool = false) {
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.colorDepth = colorDepth
        self.scaled = scaled
        self.x = x
        self.y = y
        self.rotation = rotation
        self.enabled = enabled
        self.modeNumber = modeNumber
        self.quiet = quiet
    }
}

public struct DisplayMode: Codable, Hashable, Sendable {
    public var number: Int
    public var width: Int
    public var height: Int
    public var refreshRate: Int?
    public var colorDepth: Int
    public var scaled: Bool
    public var current: Bool

    public init(number: Int, width: Int, height: Int, refreshRate: Int? = nil,
                colorDepth: Int = 8, scaled: Bool = false, current: Bool = false) {
        self.number = number
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.colorDepth = colorDepth
        self.scaled = scaled
        self.current = current
    }
}

public struct DisplaySnapshot: Codable, Hashable, Sendable {
    public var id: UInt32
    public var uuid: String
    public var name: String
    public var identity: HardwareIdentity
    public var settings: DisplaySettings
    public var modes: [DisplayMode]
    public var mirrorPrimaryID: UInt32?
    public var warnings: [String]

    public init(id: UInt32, uuid: String, name: String, identity: HardwareIdentity,
                settings: DisplaySettings, modes: [DisplayMode] = [],
                mirrorPrimaryID: UInt32? = nil, warnings: [String] = []) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.identity = identity
        self.settings = settings
        self.modes = modes
        self.mirrorPrimaryID = mirrorPrimaryID
        self.warnings = warnings
    }
}

public struct DisplaySelector: Codable, Hashable, Sendable {
    public var vendor: UInt32?
    public var product: UInt32?
    public var serialText: String?
    public var serialNumber: UInt32?
    public var edidSHA256: String?
    public var builtin: Bool?

    public init(vendor: UInt32? = nil, product: UInt32? = nil, serialText: String? = nil,
                serialNumber: UInt32? = nil, edidSHA256: String? = nil, builtin: Bool? = nil) {
        self.vendor = vendor
        self.product = product
        self.serialText = serialText
        self.serialNumber = serialNumber
        self.edidSHA256 = edidSHA256
        self.builtin = builtin
    }
}

public struct ProfileDisplay: Codable, Hashable, Sendable {
    public var key: String
    public var label: String
    public var match: DisplaySelector
    public var settings: DisplaySettings
    public var mirrors: [String]

    public init(key: String, label: String, match: DisplaySelector,
                settings: DisplaySettings, mirrors: [String] = []) {
        self.key = key
        self.label = label
        self.match = match
        self.settings = settings
        self.mirrors = mirrors
    }
}

public struct DisplayProfile: Codable, Hashable, Sendable {
    public var version: Int
    public var name: String
    public var displays: [ProfileDisplay]

    public init(version: Int = 2, name: String, displays: [ProfileDisplay]) {
        self.version = version
        self.name = name
        self.displays = displays
    }
}
