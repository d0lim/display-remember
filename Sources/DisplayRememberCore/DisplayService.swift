import Foundation

/// Serializes higher-level operations through its caller (CLI or the app's worker queue).
public final class DisplayService {
    public let engine: DisplayPlacerEngine
    private let readInventory: () throws -> [DisplaySnapshot]

    public init(engineURL: URL? = nil) throws {
        let nativeEngine = try DisplayPlacerEngine(executableURL: engineURL)
        let scanner = try NativeDisplayScanner()
        engine = nativeEngine
        readInventory = {
            let before = try scanner.snapshotIDs()
            let output = try nativeEngine.run(arguments: ["list"])
            guard output.status == 0 else { throw DisplayRememberError(output.stderr) }
            return try scanner.enrich(DisplayPlacerParser.parse(output.stdout), expected: before)
        }
    }

    init(engine: DisplayPlacerEngine, inventory: @escaping () throws -> [DisplaySnapshot]) {
        self.engine = engine
        readInventory = inventory
    }

    public func inventory() throws -> [DisplaySnapshot] {
        try readInventory()
    }

    public func capture(name: String) throws -> DisplayProfile {
        let first = try inventory()
        let profile = try ProfileBuilder.capture(name: name, displays: first)
        guard first == (try inventory()) else {
            throw DisplayRememberError("Displays changed while saving. Wait for the connection to settle.")
        }
        return profile
    }

    public func apply(_ profile: DisplayProfile, shouldProceed: () -> Bool = { true }) throws {
        let observed = try inventory()
        if try ProfileMatcher.matches(profile: profile, displays: observed) { return }
        let arguments = try ProfileMatcher.arguments(profile: profile, displays: observed)
        try applyArguments(arguments, expected: observed, shouldProceed: shouldProceed)
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 1)
            if try ProfileMatcher.matches(profile: profile, displays: inventory()) { return }
        }
        throw DisplayRememberError("The display engine completed, but macOS did not retain every requested setting.")
    }

    public func applyArguments(_ arguments: [String], expected: [DisplaySnapshot], shouldProceed: () -> Bool = { true }) throws {
        guard expected == (try inventory()) else {
            throw DisplayRememberError("Displays changed before applying. Refresh and try again.")
        }
        guard shouldProceed() else { throw DisplayRememberError("Automatic restore cancelled.") }
        let result = try engine.run(arguments: arguments)
        guard result.status == 0 else {
            throw DisplayRememberError("Display engine failed (\(result.status)): \(result.stderr)")
        }
    }

    public func applyManual(displayID: UInt32, settings: DisplaySettings, mirrorPrimaryID: UInt32?,
                            makeMain: Bool, expected: [DisplaySnapshot]) throws {
        let profile = try ManualPlan.profile(displays: expected, displayID: displayID, settings: settings,
                                             mirrorPrimaryID: mirrorPrimaryID, makeMain: makeMain)
        if try ManualPlan.matches(profile: profile, displays: inventory()) { return }
        let arguments = try ManualPlan.arguments(displays: expected, displayID: displayID, settings: settings,
                                                 mirrorPrimaryID: mirrorPrimaryID, makeMain: makeMain)
        try applyArguments(arguments, expected: expected)
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 1)
            if try ManualPlan.matches(profile: profile, displays: inventory()) { return }
        }
        throw DisplayRememberError("The engine completed, but the requested display settings could not be verified.")
    }

    public static func preview(_ arguments: [String]) -> String {
        (["display-remember", "displayplacer"] + arguments).map { value in
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}

public enum ProfileStorage {
    public static func read(_ url: URL) throws -> DisplayProfile {
        let data = try Data(contentsOf: url)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["version"] as? Int == 1 {
            return try LegacyProfileImporter.read(data: data, name: url.deletingPathExtension().lastPathComponent)
        }
        let profile = try JSONDecoder().decode(DisplayProfile.self, from: data)
        _ = try ProfileValidation.profile(profile)
        return profile
    }

    public static func write(_ profile: DisplayProfile, to url: URL, overwrite: Bool = false) throws {
        _ = try ProfileValidation.profile(profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(profile)
        if !overwrite && FileManager.default.fileExists(atPath: url.path) {
            throw DisplayRememberError("A profile already exists at \(url.path). Choose another name.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: overwrite ? [.atomic] : [.withoutOverwriting])
    }

}
