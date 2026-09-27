import XCTest
@testable import DisplayRememberCore

final class ManualPlanTests: XCTestCase {
    private func displays(mirrored: Bool = false) -> [DisplaySnapshot] {
        [
            DisplaySnapshot(
                id: 3, uuid: "MAIN-UUID", name: "Main display",
                identity: HardwareIdentity(vendor: 20588, product: 8208, serialText: "PHYSICAL-A"),
                settings: DisplaySettings(width: 1920, height: 1080, refreshRate: 60,
                    scaled: false, x: 0, y: 0, rotation: 0, modeNumber: 10)
            ),
            DisplaySnapshot(
                id: 2, uuid: "SIDE-UUID", name: "Side display",
                identity: HardwareIdentity(vendor: 20588, product: 8208, serialText: "PHYSICAL-B"),
                settings: DisplaySettings(width: mirrored ? 1920 : 1280, height: mirrored ? 1080 : 1024,
                    refreshRate: 60, scaled: false, x: mirrored ? 0 : 1920, y: 0,
                    rotation: 0, modeNumber: 20),
                mirrorPrimaryID: mirrored ? 3 : nil
            )
        ]
    }

    func testSelectedSemanticSettingsAreExplicitAndOtherScreenKeepsItsSettings() throws {
        let current = displays()
        let settings = DisplaySettings(width: 1440, height: 2560, refreshRate: 144,
            colorDepth: 10, scaled: true, x: -1440, y: 120, rotation: 270)
        let arguments = try ManualPlan.arguments(displays: current, displayID: 2,
            settings: settings, mirrorPrimaryID: nil)
        XCTAssertEqual(arguments, [
            "id:3 res:1920x1080 hz:60 color_depth:8 scaling:off origin:(0,0) degree:0 enabled:true",
            "id:2 res:1440x2560 hz:144 color_depth:10 scaling:on origin:(-1440,120) degree:270 enabled:true"
        ])
        XCTAssertEqual(current[1].settings.width, 1280, "Planning must not mutate the caller's snapshot.")
    }

    func testExplicitSelectedModeIsKeptAndOtherTransientModeIsDropped() throws {
        let current = displays()
        var settings = current[1].settings
        settings.modeNumber = 7
        let arguments = try ManualPlan.arguments(displays: current, displayID: 2,
            settings: settings, mirrorPrimaryID: nil)
        XCTAssertTrue(arguments[0].contains("res:1920x1080"))
        XCTAssertFalse(arguments[0].contains("mode:"))
        XCTAssertEqual(arguments[1], "id:2 mode:7 origin:(1920,0) degree:0 enabled:true")
    }

    func testMakeMainTranslatesEveryOriginRelativeToTheSelectedScreen() throws {
        let current = displays()
        var settings = current[1].settings
        settings.modeNumber = nil
        settings.y = 200
        let profile = try ManualPlan.profile(displays: current, displayID: 2,
            settings: settings, mirrorPrimaryID: nil, makeMain: true)
        let main = try XCTUnwrap(profile.displays.first { $0.key == "3" })
        let selected = try XCTUnwrap(profile.displays.first { $0.key == "2" })
        XCTAssertEqual(main.settings.x, -1920)
        XCTAssertEqual(main.settings.y, -200)
        XCTAssertEqual(selected.settings.x, 0)
        XCTAssertEqual(selected.settings.y, 0)
    }

    func testMakeMainRejectsOutOfRangeOriginBeforeArithmeticCanOverflow() {
        let current = displays()
        for invalid in [Int.min, Int.max] {
            var settings = current[1].settings
            settings.x = invalid
            XCTAssertThrowsError(try ManualPlan.profile(displays: current, displayID: 2,
                settings: settings, mirrorPrimaryID: nil, makeMain: true))
        }
    }

    func testMakeMainRejectsTranslationOutsideTheSupportedCoordinateRange() {
        var current = displays()
        current[0].settings.x = Int(Int32.min)
        current[1].settings.x = Int(Int32.max)
        XCTAssertThrowsError(try ManualPlan.profile(displays: current, displayID: 2,
            settings: current[1].settings, mirrorPrimaryID: nil, makeMain: true))
    }

    func testDisablingMirrorFollowerDetachesItFromTheGroup() throws {
        let current = displays(mirrored: true)
        var settings = current[1].settings
        settings.enabled = false
        let profile = try ManualPlan.profile(displays: current, displayID: 2,
            settings: settings, mirrorPrimaryID: 3)
        XCTAssertTrue(try XCTUnwrap(profile.displays.first { $0.key == "3" }).mirrors.isEmpty)
        XCTAssertFalse(try XCTUnwrap(profile.displays.first { $0.key == "2" }).settings.enabled)
        let arguments = try ManualPlan.arguments(displays: current, displayID: 2,
            settings: settings, mirrorPrimaryID: 3)
        XCTAssertEqual(arguments.count, 2)
        XCTAssertEqual(arguments[1], "id:2 enabled:false")
        XCTAssertFalse(arguments[0].contains("+2"))
    }

    func testCreatingMirrorGroupUsesOnlyLeaderSettings() throws {
        let current = displays()
        var followerSettings = current[1].settings
        followerSettings.modeNumber = nil
        let arguments = try ManualPlan.arguments(displays: current, displayID: 2,
            settings: followerSettings, mirrorPrimaryID: 3)
        XCTAssertEqual(arguments, [
            "id:3+2 res:1920x1080 hz:60 color_depth:8 scaling:off origin:(0,0) degree:0 enabled:true"
        ])
    }

    func testExistingMirrorFollowerCannotSilentlyDiscardIndependentSettings() {
        let current = displays(mirrored: true)
        var settings = current[1].settings
        settings.modeNumber = nil
        settings.width = 2560
        XCTAssertThrowsError(try ManualPlan.profile(displays: current, displayID: 2,
            settings: settings, mirrorPrimaryID: 3))
    }

    func testMissingSelectedDisplayOrMirrorSourceIsRejected() {
        let current = displays()
        XCTAssertThrowsError(try ManualPlan.profile(displays: current, displayID: 999,
            settings: current[1].settings, mirrorPrimaryID: nil))
        XCTAssertThrowsError(try ManualPlan.profile(displays: current, displayID: 2,
            settings: current[1].settings, mirrorPrimaryID: 999))
    }

    func testMirrorCycleAndSelfMirroringAreRejected() {
        let current = displays(mirrored: true)
        XCTAssertThrowsError(try ManualPlan.profile(displays: current, displayID: 3,
            settings: current[0].settings, mirrorPrimaryID: 2))
        XCTAssertThrowsError(try ManualPlan.profile(displays: current, displayID: 2,
            settings: current[1].settings, mirrorPrimaryID: 2))
    }

    func testManualVerificationChecksTheRequestedStateWithRealHardwareIdentities() throws {
        let before = displays()
        var settings = before[1].settings
        settings.modeNumber = nil
        settings.width = 2560
        settings.height = 1440
        let profile = try ManualPlan.profile(displays: before, displayID: 2,
            settings: settings, mirrorPrimaryID: nil)
        XCTAssertFalse(try ManualPlan.matches(profile: profile, displays: before))
        var applied = before
        applied[1].settings = settings
        XCTAssertTrue(try ManualPlan.matches(profile: profile, displays: applied))
        XCTAssertEqual(applied[1].identity.serialText, "PHYSICAL-B", "Manual verification must preserve real inventory identities.")
        applied[1].settings.width = 1280
        XCTAssertFalse(try ManualPlan.matches(profile: profile, displays: applied))
    }
}
