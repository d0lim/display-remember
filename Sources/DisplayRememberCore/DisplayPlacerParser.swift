import Foundation

/// Parses modern displayplacer list output without executing its printed command.
public enum DisplayPlacerParser {
    private struct Block {
        var fields: [String: String] = [:]
        var modes: [DisplayMode] = []
    }

    public static func parse(_ text: String) throws -> [DisplaySnapshot] {
        let required: Set<String> = ["Persistent screen id", "Contextual screen id", "Resolution",
            "Hertz", "Color Depth", "Scaling", "Origin", "Rotation", "Enabled"]
        var block: Block?
        var displays: [DisplaySnapshot] = []
        var footer: String?
        var inFooter = false

        func finish(_ block: Block?) throws {
            guard let block else { return }
            let missing = required.subtracting(block.fields.keys)
            guard missing.isEmpty else {
                throw DisplayRememberError("Incomplete displayplacer block: missing \(missing.sorted().joined(separator: ", ")).")
            }
            let fields = block.fields
            guard let uuid = fields["Persistent screen id"], UUID(uuidString: uuid) != nil,
                  let identifier = fields["Contextual screen id"].flatMap(UInt32.init), identifier > 0,
                  let resolution = captures(#"^(\d+)x(\d+)$"#, fields["Resolution"]!),
                  let width = Int(resolution[0]), let height = Int(resolution[1]),
                  let depth = fields["Color Depth"].flatMap(Int.init),
                  let origin = captures(#"^\((-?\d+),(-?\d+)\)(?: - main display)?$"#, fields["Origin"]!),
                  let x = Int(origin[0]), let y = Int(origin[1]),
                  let rotation = captures(#"^(\d+)(?: - rotate internal screen example .+)?$"#, fields["Rotation"]!),
                  let degrees = Int(rotation[0]) else {
                throw DisplayRememberError("Malformed display ID, resolution, depth, origin, or rotation in displayplacer output.")
            }
            guard ["on", "off"].contains(fields["Scaling"]!), ["true", "false"].contains(fields["Enabled"]!) else {
                throw DisplayRememberError("Malformed scaling or enabled state in displayplacer output.")
            }
            let hertz: Int?
            if fields["Hertz"] == "N/A" { hertz = nil }
            else {
                guard let value = fields["Hertz"].flatMap(Int.init) else {
                    throw DisplayRememberError("Malformed Hertz in displayplacer output.")
                }
                hertz = value
            }
            let currentModes = block.modes.filter(\.current)
            guard currentModes.count <= 1, Set(block.modes.map(\.number)).count == block.modes.count else {
                throw DisplayRememberError("Duplicate or conflicting mode entries in displayplacer output.")
            }
            let settings = DisplaySettings(width: width, height: height, refreshRate: hertz,
                colorDepth: depth, scaled: fields["Scaling"] == "on", x: x, y: y,
                rotation: degrees, enabled: fields["Enabled"] == "true", modeNumber: currentModes.first?.number)
            try ProfileValidation.settings(settings)
            let type = fields["Type"] ?? "Display \(identifier)"
            let serial = fields["Serial screen id"].flatMap { UInt32($0.dropFirst()) } ?? 0
            displays.append(DisplaySnapshot(id: identifier, uuid: uuid, name: type,
                identity: HardwareIdentity(vendor: 0, product: 0, serialNumber: serial,
                    builtin: type.lowercased().contains("built in")),
                settings: settings, modes: block.modes))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("Persistent screen id:") {
                guard !inFooter else { throw DisplayRememberError("Display block occurs after the profile footer.") }
                try finish(block)
                block = Block()
            }
            if line.hasPrefix("Execute the command below") {
                try finish(block)
                block = nil
                inFooter = true
                continue
            }
            if line == "displayplacer" || line.hasPrefix("displayplacer ") {
                guard footer == nil else { throw DisplayRememberError("Duplicate displayplacer profile footer.") }
                try finish(block)
                block = nil
                inFooter = true
                footer = line
                continue
            }
            guard var current = block else {
                throw DisplayRememberError("Unexpected displayplacer output: \(line.prefix(100)).")
            }
            if line.hasPrefix("mode ") {
                current.modes.append(try parseMode(line))
                block = current
                continue
            }
            if captures(#"^Resolutions for rotation \d+:$"#, line) != nil { continue }
            guard let colon = line.firstIndex(of: ":") else {
                throw DisplayRememberError("Malformed displayplacer line: \(line.prefix(100)).")
            }
            let key = String(line[..<colon])
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard required.contains(key) || key == "Type" || key == "Serial screen id",
                  current.fields[key] == nil else {
                throw DisplayRememberError("Unknown or duplicate displayplacer field: \(key).")
            }
            if key == "Serial screen id", captures(#"^s\d+$"#, value) == nil {
                throw DisplayRememberError("Malformed serial screen ID.")
            }
            current.fields[key] = value
            block = current
        }
        try finish(block)
        guard !displays.isEmpty else { throw DisplayRememberError("displayplacer returned no displays.") }
        guard Set(displays.map(\.id)).count == displays.count,
              Set(displays.map { $0.uuid.lowercased() }).count == displays.count else {
            throw DisplayRememberError("displayplacer returned duplicate screen IDs.")
        }
        if let footer { try applyMirrorFooter(footer, displays: &displays) }
        return displays
    }

    private static func parseMode(_ line: String) throws -> DisplayMode {
        guard let parts = captures(#"^mode (\d+): res:(\d+)x(\d+)(?: hz:(\d+))? color_depth:(\d+)(?: scaling:(on|off))?(?: (<-- current mode))?$"#, line),
              let number = Int(parts[0]), let width = Int(parts[1]), let height = Int(parts[2]),
              let depth = Int(parts[4]) else {
            throw DisplayRememberError("Malformed display mode: \(line.prefix(100)).")
        }
        let hertz = parts[3].isEmpty ? nil : Int(parts[3])
        guard parts[3].isEmpty || hertz != nil else { throw DisplayRememberError("Invalid mode Hertz.") }
        let mode = DisplayMode(number: number, width: width, height: height, refreshRate: hertz,
            colorDepth: depth, scaled: parts[5] == "on", current: !parts[6].isEmpty)
        try ProfileValidation.settings(DisplaySettings(width: width, height: height,
            refreshRate: hertz, colorDepth: depth, scaled: mode.scaled, modeNumber: number))
        return mode
    }

    private static func applyMirrorFooter(_ text: String, displays: inout [DisplaySnapshot]) throws {
        var remainder = text.dropFirst("displayplacer".count)[...]
        var groups: [[String]] = []
        while true {
            remainder = remainder.drop(while: { $0.isWhitespace })
            if remainder.isEmpty { break }
            guard remainder.first == "\"" else { throw DisplayRememberError("Malformed profile footer argument.") }
            remainder = remainder.dropFirst()
            guard let closing = remainder.firstIndex(of: "\"") else {
                throw DisplayRememberError("Unterminated profile footer argument.")
            }
            let argument = remainder[..<closing]
            remainder = remainder[remainder.index(after: closing)...]
            let tokens = argument.split(whereSeparator: \.isWhitespace)
            guard let identity = tokens.first, identity.hasPrefix("id:"), identity.count > 3 else {
                throw DisplayRememberError("Profile footer lacks a screen ID.")
            }
            groups.append(identity.dropFirst(3).split(separator: "+", omittingEmptySubsequences: false).map(String.init))
        }
        guard !groups.isEmpty else { throw DisplayRememberError("Empty displayplacer profile footer.") }
        var assigned: Set<UInt32> = []
        for group in groups {
            var indexes: [Int] = []
            for token in group {
                let matches = displays.indices.filter {
                    displays[$0].uuid.caseInsensitiveCompare(token) == .orderedSame || String(displays[$0].id) == token
                }
                guard matches.count == 1, let index = matches.first else {
                    throw DisplayRememberError("Unknown or ambiguous screen ID in profile footer.")
                }
                guard assigned.insert(displays[index].id).inserted else {
                    throw DisplayRememberError("Screen appears more than once in profile footer.")
                }
                indexes.append(index)
            }
            guard let primary = indexes.first else { throw DisplayRememberError("Empty mirror group.") }
            for index in indexes.dropFirst() { displays[index].mirrorPrimaryID = displays[primary].id }
        }
        guard assigned.count == displays.count else {
            throw DisplayRememberError("Profile footer does not cover every listed display.")
        }
    }

    private static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
    }
}
