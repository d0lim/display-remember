import Foundation

enum ProfileValidation {
    static func settings(_ value: DisplaySettings) throws {
        let needsDimensions = value.enabled && value.modeNumber == nil
        let minimum = needsDimensions ? 1 : 0
        guard (minimum...65535).contains(value.width), (minimum...65535).contains(value.height) else {
            throw DisplayRememberError("Display dimensions are invalid.")
        }
        if let rate = value.refreshRate, !(1...10000).contains(rate) {
            throw DisplayRememberError("Refresh rate must be between 1 and 10000 Hertz.")
        }
        guard ((value.enabled ? 1 : 0)...128).contains(value.colorDepth),
              [0, 90, 180, 270].contains(value.rotation),
              (Int(Int32.min)...Int(Int32.max)).contains(value.x),
              (Int(Int32.min)...Int(Int32.max)).contains(value.y) else {
            throw DisplayRememberError("Invalid color depth, rotation, or display origin.")
        }
        if let number = value.modeNumber, !(0...Int(Int32.max)).contains(number) {
            throw DisplayRememberError("Mode number must be a nonnegative 32-bit integer.")
        }
    }

    static func normalizedHash(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let valid = value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
        guard valid else { throw DisplayRememberError("EDID SHA-256 must contain exactly 64 hexadecimal characters.") }
        return value.lowercased()
    }

    static func normalizedSerial(_ value: String) throws -> String {
        let serial = HardwareIdentity.normalizedSerialText(value)
        guard serial.count <= 128, !serial.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { throw DisplayRememberError("Display serial contains invalid characters or is too long.") }
        return serial
    }

    static func inventory(_ displays: [DisplaySnapshot]) throws {
        guard !displays.isEmpty else { throw DisplayRememberError("No displays are connected.") }
        guard Set(displays.map(\.id)).count == displays.count, !displays.contains(where: { $0.id == 0 }) else {
            throw DisplayRememberError("Inventory contains invalid or duplicate contextual IDs.")
        }
        let byID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        for display in displays {
            try settings(display.settings)
            _ = try normalizedSerial(display.identity.serialText)
            _ = try normalizedHash(display.identity.edidSHA256)
            if let parent = display.mirrorPrimaryID {
                guard parent != display.id, let primary = byID[parent], primary.mirrorPrimaryID == nil,
                      primary.settings.enabled, display.settings.enabled else {
                    throw DisplayRememberError("Inventory contains an invalid mirror group.")
                }
            }
        }
    }

    static func selector(_ value: DisplaySelector) throws -> DisplaySelector {
        let count = [value.serialText != nil, value.serialNumber != nil,
            value.edidSHA256 != nil, value.builtin != nil].filter { $0 }.count
        guard count == 1 else { throw DisplayRememberError("A selector must contain exactly one stable identity type.") }
        if value.builtin != nil {
            guard value.builtin == true, value.vendor == nil, value.product == nil else {
                throw DisplayRememberError("Built-in fallback must be exactly builtin: true.")
            }
            return DisplaySelector(builtin: true)
        }
        guard let vendor = value.vendor, let product = value.product else {
            throw DisplayRememberError("Serial and EDID selectors require vendor and product IDs.")
        }
        if let text = value.serialText {
            let serial = try normalizedSerial(text)
            guard !serial.isEmpty else { throw DisplayRememberError("Serial selector is empty or a placeholder.") }
            return DisplaySelector(vendor: vendor, product: product, serialText: serial)
        }
        if let number = value.serialNumber {
            guard number != 0 && number != UInt32.max else { throw DisplayRememberError("Numeric serial is a placeholder.") }
            return DisplaySelector(vendor: vendor, product: product, serialNumber: number)
        }
        return DisplaySelector(vendor: vendor, product: product,
            edidSHA256: try normalizedHash(value.edidSHA256))
    }

    /// Returns each mirrored follower's profile key mapped to its leader key.
    static func profile(_ profile: DisplayProfile) throws -> [String: String] {
        guard profile.version == 2 else { throw DisplayRememberError("Unsupported profile version; expected version 2.") }
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !profile.displays.isEmpty else { throw DisplayRememberError("Profile name and displays are required.") }
        let keys = profile.displays.map(\.key)
        guard keys.allSatisfy({ !$0.isEmpty }), Set(keys).count == keys.count else {
            throw DisplayRememberError("Profile display keys must be nonempty and unique.")
        }
        let byKey = Dictionary(uniqueKeysWithValues: profile.displays.map { ($0.key, $0) })
        var parents: [String: String] = [:]
        for display in profile.displays {
            guard !display.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DisplayRememberError("Every profile display needs a label.")
            }
            _ = try selector(display.match)
            try settings(display.settings)
            for key in display.mirrors {
                guard key != display.key, let follower = byKey[key], follower.mirrors.isEmpty,
                      parents[key] == nil, display.settings.enabled, follower.settings.enabled else {
                    throw DisplayRememberError("Invalid mirror group: missing, repeated, nested, self, or disabled member.")
                }
                parents[key] = display.key
            }
        }
        let enabledLeaders = profile.displays.filter { $0.settings.enabled && parents[$0.key] == nil }
        if !enabledLeaders.isEmpty && enabledLeaders.filter({ $0.settings.x == 0 && $0.settings.y == 0 }).count != 1 {
            throw DisplayRememberError("Exactly one enabled mirror-group leader must have origin (0,0).")
        }
        return parents
    }
}

public enum ProfileBuilder {
    /// Captures all physical displays. OS display IDs and transient mode indices are never saved as identity.
    public static func capture(name: String, displays: [DisplaySnapshot]) throws -> DisplayProfile {
        try ProfileValidation.inventory(displays)
        let builtinCount = displays.filter { $0.identity.builtin }.count
        let keys = Dictionary(uniqueKeysWithValues: displays.enumerated().map { ($0.element.id, "display-\($0.offset + 1)") })
        let entries = try displays.map { display -> ProfileDisplay in
            let identity = display.identity
            let text = try ProfileValidation.normalizedSerial(identity.serialText)
            let selector: DisplaySelector
            if !text.isEmpty {
                selector = DisplaySelector(vendor: identity.vendor, product: identity.product, serialText: text)
            } else if identity.serialNumber != 0 && identity.serialNumber != UInt32.max {
                selector = DisplaySelector(vendor: identity.vendor, product: identity.product, serialNumber: identity.serialNumber)
            } else if let hash = try ProfileValidation.normalizedHash(identity.edidSHA256) {
                selector = DisplaySelector(vendor: identity.vendor, product: identity.product, edidSHA256: hash)
            } else if identity.builtin && builtinCount == 1 {
                selector = DisplaySelector(builtin: true)
            } else {
                throw DisplayRememberError("\(display.name) has no stable serial or EDID identity; UUID and port fallback are disabled.")
            }
            var settings = display.settings
            settings.modeNumber = nil
            settings.quiet = false
            return ProfileDisplay(key: keys[display.id]!, label: display.name, match: selector, settings: settings,
                mirrors: displays.filter { $0.mirrorPrimaryID == display.id }.compactMap { keys[$0.id] })
        }
        let profile = DisplayProfile(name: name, displays: entries)
        _ = try ProfileMatcher.resolve(profile: profile, displays: displays)
        return profile
    }
}

public enum ProfileMatcher {
    /// Argument groups only: pass them to Process.arguments with the executable supplied separately.
    public static func arguments(profile: DisplayProfile, displays: [DisplaySnapshot]) throws -> [String] {
        let resolved = try resolve(profile: profile, displays: displays)
        let followers = Set(profile.displays.flatMap(\.mirrors))
        return profile.displays.filter { !followers.contains($0.key) }.map { display in
            let settings = display.settings
            let identifiers = ([display.key] + display.mirrors).map { String(resolved[$0]!.id) }.joined(separator: "+")
            var parts = ["id:\(identifiers)"]
            if settings.enabled {
                if let mode = settings.modeNumber { parts.append("mode:\(mode)") }
                else {
                    parts.append("res:\(settings.width)x\(settings.height)")
                    if let rate = settings.refreshRate { parts.append("hz:\(rate)") }
                    parts.append("color_depth:\(settings.colorDepth)")
                    parts.append("scaling:\(settings.scaled ? "on" : "off")")
                }
                parts.append("origin:(\(settings.x),\(settings.y))")
                parts.append("degree:\(settings.rotation)")
            }
            parts.append("enabled:\(settings.enabled ? "true" : "false")")
            if settings.quiet { parts.append("quiet:true") }
            return parts.joined(separator: " ")
        }
    }

    /// Verifies requested hardware state. Omitted Hertz and error-output policy are not hardware constraints.
    public static func matches(profile: DisplayProfile, displays: [DisplaySnapshot]) throws -> Bool {
        let resolved = try resolve(profile: profile, displays: displays)
        let parents = try ProfileValidation.profile(profile)
        let savedByKey = Dictionary(uniqueKeysWithValues: profile.displays.map { ($0.key, $0) })
        for display in profile.displays {
            let current = resolved[display.key]!
            let expectedParentID = parents[display.key].flatMap { resolved[$0]?.id }
            guard current.mirrorPrimaryID == expectedParentID else { return false }
            if let parentKey = parents[display.key] {
                // displayplacer applies the group's degree to every physical member.
                guard current.settings.enabled,
                      current.settings.rotation == savedByKey[parentKey]!.settings.rotation else { return false }
                continue
            }
            let target = display.settings
            let actual = current.settings
            guard target.enabled == actual.enabled else { return false }
            if !target.enabled { continue }
            guard target.x == actual.x, target.y == actual.y, target.rotation == actual.rotation else { return false }
            if let mode = target.modeNumber {
                let currentMode = actual.modeNumber ?? current.modes.first(where: \.current)?.number
                guard mode == currentMode else { return false }
            } else {
                guard target.width == actual.width, target.height == actual.height,
                      target.colorDepth == actual.colorDepth, target.scaled == actual.scaled else { return false }
                if let rate = target.refreshRate, rate != actual.refreshRate { return false }
            }
        }
        return true
    }

    static func resolve(profile: DisplayProfile, displays: [DisplaySnapshot]) throws -> [String: DisplaySnapshot] {
        _ = try ProfileValidation.profile(profile)
        try ProfileValidation.inventory(displays)
        guard profile.displays.count == displays.count else {
            throw DisplayRememberError("Display set differs: profile has \(profile.displays.count), connected has \(displays.count). Missing or extra displays are not allowed.")
        }
        var result: [String: DisplaySnapshot] = [:]
        var used: Set<UInt32> = []
        for display in profile.displays {
            let selector = try ProfileValidation.selector(display.match)
            let candidates = try displays.filter { current in
                let identity = current.identity
                if selector.builtin == true { return identity.builtin }
                guard selector.vendor == identity.vendor, selector.product == identity.product else { return false }
                if let text = selector.serialText { return text == (try ProfileValidation.normalizedSerial(identity.serialText)) }
                if let number = selector.serialNumber { return number == identity.serialNumber }
                return selector.edidSHA256 == (try ProfileValidation.normalizedHash(identity.edidSHA256))
            }
            guard !candidates.isEmpty else { throw DisplayRememberError("Missing display matching \(display.label).") }
            guard candidates.count == 1, let candidate = candidates.first else {
                throw DisplayRememberError("Ambiguous hardware identity for \(display.label); refusing to choose by UUID or port.")
            }
            guard used.insert(candidate.id).inserted else {
                throw DisplayRememberError("Duplicate assignment: \(display.label) selects an already matched display.")
            }
            result[display.key] = candidate
        }
        return result
    }
}
