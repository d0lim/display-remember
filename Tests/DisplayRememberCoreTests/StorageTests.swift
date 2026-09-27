import Foundation
import XCTest
@testable import DisplayRememberCore

final class StorageTests: XCTestCase {
    private var directory: URL!
    private let fixture = """
    {"version":1,"displays":[{"label":"Monitor A","match":{"vendor":20588,"product":8208,"serial_text":"MONITOR-A"},"settings":{"res":"1920x1080","hz":60,"color_depth":8,"scaling":"on","origin":[0,0],"degree":0,"enabled":true}}]}
    """

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("display-remember-storage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func legacy(replacing old: String = "", with replacement: String = "") -> Data {
        Data((old.isEmpty ? fixture : fixture.replacingOccurrences(of: old, with: replacement)).utf8)
    }

    private func currentProfile(name: String = "Desk") -> DisplayProfile {
        DisplayProfile(name: name, displays: [
            ProfileDisplay(key: "main", label: "Monitor A",
                match: DisplaySelector(vendor: 20588, product: 8208, serialText: "MONITOR-A"),
                settings: DisplaySettings(width: 1920, height: 1080, refreshRate: 60, scaled: true))
        ])
    }

    func testLegacyProfileConvertsRequiredSettingsAndStableSelector() throws {
        let result = try LegacyProfileImporter.read(data: legacy(), name: "Imported desk")
        XCTAssertEqual(result.version, 2)
        XCTAssertEqual(result.name, "Imported desk")
        XCTAssertEqual(result.displays.count, 1)
        let display = try XCTUnwrap(result.displays.first)
        XCTAssertEqual(display.key, "display-1")
        XCTAssertEqual(display.label, "Monitor A")
        XCTAssertEqual(display.match, currentProfile().displays[0].match)
        XCTAssertEqual(display.settings, currentProfile().displays[0].settings)
        XCTAssertTrue(display.mirrors.isEmpty)
    }

    func testLegacyHertzMayBeOmittedButNotNull() throws {
        let omitted = legacy(replacing: "\"hz\":60,", with: "")
        XCTAssertNil(try LegacyProfileImporter.read(data: omitted, name: "Desk").displays[0].settings.refreshRate)
        XCTAssertThrowsError(try LegacyProfileImporter.read(
            data: legacy(replacing: "\"hz\":60", with: "\"hz\":null"), name: "Desk"))
    }

    func testLegacyRequiredFieldsCannotBeOmittedOrDefaulted() {
        let required = ["\"label\":\"Monitor A\",", "\"res\":\"1920x1080\",", "\"color_depth\":8,",
                        "\"scaling\":\"on\",", "\"origin\":[0,0],", "\"degree\":0,", ",\"enabled\":true"]
        for field in required {
            XCTAssertThrowsError(try LegacyProfileImporter.read(data: legacy(replacing: field, with: ""), name: "Desk"), field)
        }
    }

    func testLegacyNumericFieldsRejectBooleansFractionalValuesAndOverflow() {
        let invalid: [(String, String)] = [
            ("\"vendor\":20588", "\"vendor\":-1"),
            ("\"vendor\":20588", "\"vendor\":true"),
            ("\"vendor\":20588", "\"vendor\":20588.5"),
            ("\"product\":8208", "\"product\":4294967296"),
            ("\"product\":8208", "\"product\":\"8208\""),
            ("\"color_depth\":8", "\"color_depth\":true"),
            ("\"color_depth\":8", "\"color_depth\":8.5"),
            ("\"hz\":60", "\"hz\":false"),
            ("\"degree\":0", "\"degree\":0.5"),
            ("\"origin\":[0,0]", "\"origin\":[false,0]"),
            ("\"enabled\":true", "\"enabled\":1")
        ]
        for (old, replacement) in invalid {
            XCTAssertThrowsError(try LegacyProfileImporter.read(data: legacy(replacing: old, with: replacement), name: "Desk"), replacement)
        }
    }

    func testLegacyNumericSerialIsStrictlyUnsigned() throws {
        let field = "\"serial_text\":\"MONITOR-A\""
        let numeric = legacy(replacing: field, with: "\"serial_number\":12345")
        XCTAssertEqual(try LegacyProfileImporter.read(data: numeric, name: "Desk").displays[0].match.serialNumber, 12345)
        for value in ["-1", "4294967296", "true", "1.5", "null", "0", "4294967295"] {
            XCTAssertThrowsError(try LegacyProfileImporter.read(data: legacy(replacing: field, with: "\"serial_number\":\(value)"), name: "Desk"), value)
        }
    }

    func testLegacyBuiltinAndEDIDSelectorsConvertWithoutUUIDFallback() throws {
        let oldMatch = "\"match\":{\"vendor\":20588,\"product\":8208,\"serial_text\":\"MONITOR-A\"}"
        let builtin = legacy(replacing: oldMatch, with: "\"match\":{\"builtin\":true}")
        XCTAssertEqual(try LegacyProfileImporter.read(data: builtin, name: "Desk").displays[0].match, DisplaySelector(builtin: true))
        let hash = String(repeating: "A", count: 64)
        let edid = legacy(replacing: "\"serial_text\":\"MONITOR-A\"", with: "\"edid_sha256\":\"\(hash)\"")
        XCTAssertEqual(try LegacyProfileImporter.read(data: edid, name: "Desk").displays[0].match.edidSHA256, hash.lowercased())
    }

    func testLegacyResolutionOriginAndScalingAreValidatedExactly() {
        for resolution in ["1920xx1080", "1920x1080x", "01920x1080", " 1920x1080", "0x1080", "999999999999999999999999x1080"] {
            XCTAssertThrowsError(try LegacyProfileImporter.read(data: legacy(replacing: "1920x1080", with: resolution), name: "Desk"), resolution)
        }
        for origin in ["[]", "[0]", "[0,0,0]", "[0.5,0]"] {
            XCTAssertThrowsError(try LegacyProfileImporter.read(data: legacy(replacing: "[0,0]", with: origin), name: "Desk"), origin)
        }
        XCTAssertThrowsError(try LegacyProfileImporter.read(data: legacy(replacing: "\"on\"", with: "\"yes\""), name: "Desk"))
    }

    func testLegacyUnknownKeysAndInvalidSelectorsAreRejected() {
        let invalid: [(String, String)] = [
            ("\"version\":1", "\"version\":1,\"unknown\":true"),
            ("\"label\":\"Monitor A\"", "\"label\":\"Monitor A\",\"unknown\":true"),
            ("\"vendor\":20588", "\"vendor\":20588,\"uuid\":\"PORT-UUID\""),
            ("\"degree\":0", "\"degree\":0,\"mode\":3"),
            ("\"serial_text\":\"MONITOR-A\"", "\"serial_text\":\"MONITOR-A\",\"serial_number\":42"),
            ("\"serial_text\":\"MONITOR-A\"", "\"serial_text\":null"),
            ("\"serial_text\":\"MONITOR-A\"", "\"serial_text\":\"00000000\"")
        ]
        for (old, replacement) in invalid {
            XCTAssertThrowsError(try LegacyProfileImporter.read(data: legacy(replacing: old, with: replacement), name: "Desk"), replacement)
        }
    }

    func testLegacyProfileReceivesCurrentSemanticValidation() {
        for data in [legacy(replacing: "\"version\":1", with: "\"version\":2"),
                     Data("{\"version\":1,\"displays\":[]}".utf8),
                     legacy(replacing: "\"degree\":0", with: "\"degree\":45"),
                     legacy(replacing: "[0,0]", with: "[100,100]")] {
            XCTAssertThrowsError(try LegacyProfileImporter.read(data: data, name: "Desk"))
        }
        XCTAssertThrowsError(try LegacyProfileImporter.read(data: legacy(), name: ""))
    }

    func testProfileStorageReadsLegacyAndWritesCurrentRoundTrip() throws {
        let old = directory.appendingPathComponent("Old desk.json")
        try legacy().write(to: old)
        let imported = try ProfileStorage.read(old)
        XCTAssertEqual(imported.name, "Old desk")
        XCTAssertEqual(imported.version, 2)
        let converted = directory.appendingPathComponent("Converted.json")
        try ProfileStorage.write(imported, to: converted)
        XCTAssertEqual(try ProfileStorage.read(converted), imported)
    }

    func testCurrentProfileRoundTripPreservesEveryField() throws {
        let profile = currentProfile()
        let file = directory.appendingPathComponent("Nested/Desk.json")
        try ProfileStorage.write(profile, to: file)
        XCTAssertEqual(try ProfileStorage.read(file), profile)
    }

    func testStorageRefusesOverwriteAndPreservesExistingBytes() throws {
        let file = directory.appendingPathComponent("Desk.json")
        try ProfileStorage.write(currentProfile(), to: file)
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try ProfileStorage.write(currentProfile(name: "Replacement"), to: file))
        XCTAssertEqual(try Data(contentsOf: file), original)
        try ProfileStorage.write(currentProfile(name: "Replacement"), to: file, overwrite: true)
        XCTAssertEqual(try ProfileStorage.read(file).name, "Replacement")
    }

    func testStorageValidatesCurrentProfilesOnReadAndWrite() throws {
        var invalid = currentProfile()
        invalid.displays[0].settings.rotation = 45
        let file = directory.appendingPathComponent("Invalid.json")
        XCTAssertThrowsError(try ProfileStorage.write(invalid, to: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try JSONEncoder().encode(invalid).write(to: file)
        XCTAssertThrowsError(try ProfileStorage.read(file))
    }

    func testStorageDoesNotCoerceMalformedLegacyTypesDuringVersionDispatch() throws {
        let file = directory.appendingPathComponent("Legacy.json")
        for data in [legacy(replacing: "\"vendor\":20588", with: "\"vendor\":-1"),
                     legacy(replacing: "\"version\":1", with: "\"version\":true"),
                     legacy(replacing: "\"color_depth\":8,", with: "")] {
            try data.write(to: file)
            XCTAssertThrowsError(try ProfileStorage.read(file))
        }
    }
}
