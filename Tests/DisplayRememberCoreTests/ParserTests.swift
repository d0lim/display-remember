import XCTest
@testable import DisplayRememberCore

final class ParserTests: XCTestCase {
    // Deterministic synthetic UUIDs and screen IDs; no captured hardware output.
    private func uuid(_ id: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", id) }

    private func block(_ id: Int = 1, origin: String = "(0,0) - main display", hertz: String = "60",
                       enabled: Bool = true, width: Int = 2560, height: Int = 1440) -> String {
        """
        Persistent screen id: \(uuid(id))
        Contextual screen id: \(id)
        Serial screen id: s\(id + 100)
        Type: 27 inch external screen
        Resolution: \(width)x\(height)
        Hertz: \(hertz)
        Color Depth: 8
        Scaling: on
        Origin: \(origin)
        Rotation: 0
        Enabled: \(enabled ? "true" : "false")
        Resolutions for rotation 0:
          mode 0: res:1920x1080 color_depth:8
          mode 4: res:2560x1440 hz:60 color_depth:8 scaling:on <-- current mode


        """
    }

    func testModernListingParsesModesAndCurrentSemanticSettings() throws {
        let text = block() + block(2, origin: "(-2560,0)") + """
        Execute the command below to set your screens to the current arrangement.

        displayplacer "id:\(uuid(1)) res:2560x1440" "id:\(uuid(2)) res:2560x1440"
        """
        let parsed = try DisplayPlacerParser.parse(text)
        XCTAssertEqual(parsed.map(\.id), [1, 2])
        XCTAssertEqual(parsed[0].settings.width, 2560)
        XCTAssertEqual(parsed[0].settings.modeNumber, 4)
        XCTAssertEqual(parsed[1].settings.x, -2560)
        XCTAssertEqual(parsed[0].identity.serialNumber, 101)
        XCTAssertEqual(parsed[0].modes, [
            DisplayMode(number: 0, width: 1920, height: 1080),
            DisplayMode(number: 4, width: 2560, height: 1440, refreshRate: 60, scaled: true, current: true),
        ])
    }

    func testHertzNAAndBuiltinRotationExampleAreParsed() throws {
        let text = block(hertz: "N/A")
            .replacingOccurrences(of: "Type: 27 inch external screen", with: "Type: MacBook built in screen")
            .replacingOccurrences(of: "Rotation: 0", with: "Rotation: 0 - rotate internal screen example (may crash computer, but will be rotated after rebooting): `displayplacer \"id:\(uuid(1)) degree:90\"`")
        let parsed = try DisplayPlacerParser.parse(text)
        XCTAssertNil(parsed[0].settings.refreshRate)
        XCTAssertTrue(parsed[0].identity.builtin)
    }

    func testPartialMirrorFooterAndDisabledDisplayArePreserved() throws {
        let text = block() + block(2) + block(3, origin: "(2560,0)")
            + block(4, enabled: false, width: 0, height: 0)
            + "displayplacer \"id:\(uuid(1))+\(uuid(2)) res:2560x1440\" \"id:\(uuid(3)) res:2560x1440\" \"id:\(uuid(4)) enabled:false\""
        let parsed = try DisplayPlacerParser.parse(text)
        XCTAssertEqual(parsed.count, 4)
        XCTAssertNil(parsed[0].mirrorPrimaryID)
        XCTAssertEqual(parsed[1].mirrorPrimaryID, 1)
        XCTAssertNil(parsed[2].mirrorPrimaryID)
        XCTAssertFalse(parsed[3].settings.enabled)
        XCTAssertEqual(parsed[3].settings.width, 0)
    }

    func testThreeMemberMirrorAndNumericFooterIDs() throws {
        let parsed = try DisplayPlacerParser.parse(block() + block(2) + block(3)
            + "displayplacer \"id:1+2+3 res:2560x1440\"")
        XCTAssertEqual(parsed.map(\.mirrorPrimaryID), [nil, 1, 1])
    }

    func testMalformedFieldsMissingBlocksAndDuplicateModesAreRejected() {
        let original = block()
        let invalid = ["", "backend failure", original.replacingOccurrences(of: "Hertz: 60\n", with: ""),
            original.replacingOccurrences(of: "Hertz: 60", with: "Hertz: unknown"),
            original.replacingOccurrences(of: "Scaling: on", with: "Scaling: on\nScaling: off"),
            original.replacingOccurrences(of: "Origin: (0,0)", with: "Origin: 0,0"),
            original.replacingOccurrences(of: "Rotation: 0", with: "Rotation: broken"),
            original.replacingOccurrences(of: "Enabled: true", with: "Enabled: maybe"),
            original.replacingOccurrences(of: "Contextual screen id: 1", with: "Contextual screen id: nope"),
            original.replacingOccurrences(of: "Persistent screen id:", with: "Persistent screen id: INVALID"),
            original.replacingOccurrences(of: "Type: 27 inch external screen", with: "Unexpected: value"),
            original.replacingOccurrences(of: "mode 0: res:1920x1080 color_depth:8", with: "mode 0: res:BAD"),
            original.replacingOccurrences(of: "mode 0:", with: "mode 4:"),
            original.replacingOccurrences(of: "res:1920x1080 color_depth:8", with: "res:1920x1080 color_depth:8 <-- current mode")]
        for text in invalid { XCTAssertThrowsError(try DisplayPlacerParser.parse(text), text) }
    }

    func testMalformedDuplicateUnknownAndIncompleteFooterIdentitiesFail() {
        let original = block() + block(2, origin: "(2560,0)")
        for footer in ["displayplacer", "displayplacer \"unterminated",
                       "displayplacer \"id:1+999 res:2560x1440\"",
                       "displayplacer \"id:1+1 res:2560x1440\" \"id:2 res:2560x1440\"",
                       "displayplacer \"id:1 res:2560x1440\"",
                       "displayplacer \"id:1++2 res:2560x1440\"",
                       "displayplacer \"res:2560x1440\"",
                       "displayplacer unquoted"] {
            XCTAssertThrowsError(try DisplayPlacerParser.parse(original + footer), footer)
        }
        XCTAssertThrowsError(try DisplayPlacerParser.parse(block() + block(1, origin: "(2560,0)")))
    }
}
