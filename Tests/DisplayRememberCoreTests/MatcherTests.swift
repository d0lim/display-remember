import Foundation
import XCTest
@testable import DisplayRememberCore

final class MatcherTests: XCTestCase {
    private func display(_ id: UInt32 = 1, serial: String = "LEFT-001", x: Int = 0,
                         hash: String? = String(repeating: "a", count: 64)) -> DisplaySnapshot {
        DisplaySnapshot(id: id, uuid: "old-\(id)", name: "Monitor \(serial)",
            identity: HardwareIdentity(vendor: 4268, product: 40976, serialText: serial, edidSHA256: hash),
            settings: DisplaySettings(width: 2560, height: 1440, refreshRate: 60, scaled: true, x: x),
            modes: [DisplayMode(number: 4, width: 2560, height: 1440, refreshRate: 60, scaled: true, current: true)])
    }

    func testReconnectionChangesIDsOrderAndUUIDsWithoutChangingPhysicalPlacement() throws {
        let initial = [display(), display(2, serial: "RIGHT-002", x: 2560)]
        let profile = try ProfileBuilder.capture(name: "Desk", displays: initial)
        var current = Array(initial.reversed())
        current[0].id = 77; current[0].uuid = "changed-right"
        current[1].id = 88; current[1].uuid = "changed-left"
        let arguments = try ProfileMatcher.arguments(profile: profile, displays: current)
        XCTAssertEqual(arguments, [
            "id:88 res:2560x1440 hz:60 color_depth:8 scaling:on origin:(0,0) degree:0 enabled:true",
            "id:77 res:2560x1440 hz:60 color_depth:8 scaling:on origin:(2560,0) degree:0 enabled:true",
        ])
        XCTAssertTrue(try ProfileMatcher.matches(profile: profile, displays: current))
    }

    func testSerialSurvivesEDIDHashChangeOrAbsence() throws {
        var monitor = display()
        let profile = try ProfileBuilder.capture(name: "Desk", displays: [monitor])
        XCTAssertEqual(profile.displays[0].match.serialText, "LEFT-001")
        for hash in [String(repeating: "b", count: 64), nil] {
            monitor.identity.edidSHA256 = hash
            XCTAssertTrue(try ProfileMatcher.matches(profile: profile, displays: [monitor]))
        }
    }

    func testNumericSerialBeforeHashAndPlaceholderSerialBeforeHash() throws {
        var monitor = display(serial: "000000000")
        monitor.identity.serialNumber = 9988
        XCTAssertEqual(try ProfileBuilder.capture(name: "Desk", displays: [monitor]).displays[0].match.serialNumber, 9988)
        monitor.identity.serialNumber = UInt32.max
        for placeholder in ["", "FFFFFFFF", "N/A", "unknown", "\0 \n"] {
            monitor.identity.serialText = placeholder
            XCTAssertEqual(try ProfileBuilder.capture(name: "Desk", displays: [monitor]).displays[0].match.edidSHA256,
                           String(repeating: "a", count: 64))
        }
    }

    func testHashNormalizationAndNoIdentityFallback() throws {
        var monitor = display(serial: "", hash: String(repeating: "A", count: 64))
        let profile = try ProfileBuilder.capture(name: "Desk", displays: [monitor])
        monitor.identity.edidSHA256 = String(repeating: "a", count: 64)
        XCTAssertTrue(try ProfileMatcher.matches(profile: profile, displays: [monitor]))
        monitor.identity.edidSHA256 = nil
        XCTAssertThrowsError(try ProfileBuilder.capture(name: "Desk", displays: [monitor]))
    }

    func testDuplicateSerialAndIdenticalEDIDNeverUsePortOrdering() {
        let duplicates = [display(), display(2, serial: "LEFT-001", x: 2560, hash: String(repeating: "b", count: 64))]
        XCTAssertThrowsError(try ProfileBuilder.capture(name: "Desk", displays: duplicates))
        let identicalEDID = [display(serial: ""), display(2, serial: "", x: 2560)]
        XCTAssertThrowsError(try ProfileBuilder.capture(name: "Desk", displays: identicalEDID))
    }

    func testBuiltinFallbackRequiresUniqueBuiltinDisplay() throws {
        var monitor = display(serial: "", hash: nil)
        monitor.identity.builtin = true
        let profile = try ProfileBuilder.capture(name: "Laptop", displays: [monitor])
        XCTAssertEqual(profile.displays[0].match, DisplaySelector(builtin: true))
        var second = monitor; second.id = 2; second.settings.x = 2560
        XCTAssertThrowsError(try ProfileBuilder.capture(name: "Laptop", displays: [monitor, second]))
    }

    func testMissingExtraReplacedAndRepeatedAssignmentFail() throws {
        let monitors = [display(), display(2, serial: "RIGHT", x: 2560)]
        let profile = try ProfileBuilder.capture(name: "Desk", displays: monitors)
        for current in [Array(monitors.prefix(1)), monitors + [display(3, serial: "THIRD", x: 5120)],
                        [monitors[0], display(9, serial: "REPLACEMENT", x: 2560)]] {
            XCTAssertThrowsError(try ProfileMatcher.arguments(profile: profile, displays: current))
        }
        var duplicate = profile
        duplicate.displays[1].match = DisplaySelector(vendor: 4268, product: 40976,
            edidSHA256: String(repeating: "a", count: 64))
        var distinctHashes = monitors
        distinctHashes[1].identity.edidSHA256 = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try ProfileMatcher.arguments(profile: duplicate, displays: distinctHashes))
    }

    func testCaptureUsesSemanticSettingsInsteadOfTransientModeOrQuiet() throws {
        var monitor = display()
        monitor.settings.modeNumber = 4
        monitor.settings.quiet = true
        let profile = try ProfileBuilder.capture(name: "Desk", displays: [monitor])
        XCTAssertNil(profile.displays[0].settings.modeNumber)
        XCTAssertFalse(profile.displays[0].settings.quiet)
        monitor.settings.modeNumber = 99
        XCTAssertTrue(try ProfileMatcher.matches(profile: profile, displays: [monitor]))
        let encoded = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(DisplayProfile.self, from: encoded), profile)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("old-1"))
    }

    func testAbsentHertzIsUnconstrainedButExplicitHertzRemainsRequired() throws {
        var monitor = display()
        let explicit = try ProfileBuilder.capture(name: "Desk", displays: [monitor])
        monitor.settings.refreshRate = nil
        XCTAssertFalse(try ProfileMatcher.matches(profile: explicit, displays: [monitor]))
        let unconstrained = try ProfileBuilder.capture(name: "Desk", displays: [monitor])
        monitor.settings.refreshRate = 144
        XCTAssertTrue(try ProfileMatcher.matches(profile: unconstrained, displays: [monitor]))
        XCTAssertFalse(try ProfileMatcher.arguments(profile: unconstrained, displays: [monitor])[0].contains("hz:"))
    }

    func testPartialMirroringCapturesEveryPhysicalDisplayAndFollowsNewIDs() throws {
        var follower = display(2, serial: "MIRROR")
        follower.mirrorPrimaryID = 1
        var disabled = display(4, serial: "OFF")
        disabled.settings.enabled = false
        disabled.settings.width = 0; disabled.settings.height = 0
        let initial = [display(), follower, display(3, serial: "EXTENDED", x: 2560), disabled]
        let profile = try ProfileBuilder.capture(name: "Presentation", displays: initial)
        XCTAssertEqual(profile.displays.count, 4)
        XCTAssertEqual(profile.displays[0].mirrors, [profile.displays[1].key])
        var current = initial
        current[0].id = 10; current[1].id = 20; current[1].mirrorPrimaryID = 10
        current[2].id = 30; current[3].id = 40
        current[1].settings.width = 1920; current[1].settings.height = 1080
        current[1].settings.x = 987
        let arguments = try ProfileMatcher.arguments(profile: profile, displays: Array(current.reversed()))
        XCTAssertEqual(arguments.count, 3)
        XCTAssertTrue(arguments[0].hasPrefix("id:10+20 "))
        XCTAssertTrue(arguments[1].hasPrefix("id:30 "))
        XCTAssertEqual(arguments[2], "id:40 enabled:false")
        XCTAssertTrue(try ProfileMatcher.matches(profile: profile, displays: current))
        current[1].mirrorPrimaryID = nil
        XCTAssertFalse(try ProfileMatcher.matches(profile: profile, displays: current))
    }

    func testMirrorFollowerUsesLeadersRotationRatherThanItsSavedSettings() throws {
        var follower = display(2, serial: "MIRROR")
        follower.mirrorPrimaryID = 1
        var profile = try ProfileBuilder.capture(name: "Mirror", displays: [display(), follower])
        // The saved follower's independent settings are ignored by a grouped command.
        profile.displays[1].settings.rotation = 90
        XCTAssertTrue(try ProfileMatcher.matches(profile: profile, displays: [display(), follower]))
        // But a follower's observed state must satisfy the leader's shared rotation.
        follower.settings.rotation = 90
        XCTAssertFalse(try ProfileMatcher.matches(profile: profile, displays: [display(), follower]))
    }

    func testDisablingIgnoresIrrelevantSavedResolutionAndCanReenable() throws {
        var off = display(2, serial: "OFF", x: 2560)
        off.settings.enabled = false
        let profile = try ProfileBuilder.capture(name: "Desk", displays: [display(), off])
        off.settings.width = 0; off.settings.height = 0; off.settings.refreshRate = nil
        XCTAssertTrue(try ProfileMatcher.matches(profile: profile, displays: [display(), off]))
        off.settings.enabled = true
        off.settings.width = 2560; off.settings.height = 1440
        XCTAssertFalse(try ProfileMatcher.matches(profile: profile, displays: [display(), off]))
    }

    func testExplicitModeAndQuietUseBackendFlagsWithoutCompetingResolutionFlags() throws {
        var monitor = display()
        var profile = try ProfileBuilder.capture(name: "Desk", displays: [monitor])
        profile.displays[0].settings.modeNumber = 9
        profile.displays[0].settings.quiet = true
        profile.displays[0].settings.rotation = 90
        XCTAssertEqual(try ProfileMatcher.arguments(profile: profile, displays: [monitor]),
                       ["id:1 mode:9 origin:(0,0) degree:90 enabled:true quiet:true"])
        monitor.settings.rotation = 90
        monitor.settings.modeNumber = 9
        monitor.settings.width = 1080; monitor.settings.height = 1920
        XCTAssertTrue(try ProfileMatcher.matches(profile: profile, displays: [monitor]))
        monitor.settings.modeNumber = 8
        XCTAssertFalse(try ProfileMatcher.matches(profile: profile, displays: [monitor]))
    }

    func testInvalidMirrorGraphsAreRejected() throws {
        let monitors = [display(), display(2, serial: "RIGHT", x: 2560), display(3, serial: "THIRD", x: 5120)]
        let original = try ProfileBuilder.capture(name: "Desk", displays: monitors)
        let keys = original.displays.map(\.key)
        var variants: [DisplayProfile] = []
        var selfMirror = original; selfMirror.displays[0].mirrors = [keys[0]]; variants.append(selfMirror)
        var missing = original; missing.displays[0].mirrors = ["missing"]; variants.append(missing)
        var repeated = original; repeated.displays[0].mirrors = [keys[1], keys[1]]; variants.append(repeated)
        var nested = original; nested.displays[0].mirrors = [keys[1]]; nested.displays[1].mirrors = [keys[2]]; variants.append(nested)
        var shared = original; shared.displays[0].mirrors = [keys[2]]; shared.displays[1].mirrors = [keys[2]]; variants.append(shared)
        var disabled = original; disabled.displays[0].mirrors = [keys[1]]; disabled.displays[1].settings.enabled = false; variants.append(disabled)
        for profile in variants { XCTAssertThrowsError(try ProfileMatcher.arguments(profile: profile, displays: monitors)) }
    }

    func testInvalidSelectorsSettingsAndVersionsFail() throws {
        let monitor = display()
        let original = try ProfileBuilder.capture(name: "Desk", displays: [monitor])
        let selectors: [DisplaySelector] = [DisplaySelector(), DisplaySelector(builtin: false),
            DisplaySelector(vendor: 4268, product: 40976),
            DisplaySelector(vendor: 4268, product: 40976, serialNumber: 0),
            DisplaySelector(vendor: 4268, product: 40976, serialText: "unknown"),
            DisplaySelector(vendor: 4268, product: 40976, edidSHA256: "bad"),
            DisplaySelector(vendor: 4268, product: 40976, serialText: "LEFT-001", serialNumber: 1)]
        for selector in selectors {
            var profile = original; profile.displays[0].match = selector
            XCTAssertThrowsError(try ProfileMatcher.arguments(profile: profile, displays: [monitor]))
        }
        var invalidSettings: [DisplaySettings] = []
        var settings = monitor.settings; settings.width = 0; invalidSettings.append(settings)
        settings = monitor.settings; settings.refreshRate = -1; invalidSettings.append(settings)
        settings = monitor.settings; settings.colorDepth = 0; invalidSettings.append(settings)
        settings = monitor.settings; settings.rotation = 45; invalidSettings.append(settings)
        settings = monitor.settings; settings.modeNumber = -1; invalidSettings.append(settings)
        settings = monitor.settings; settings.x = Int(Int32.max) + 1; invalidSettings.append(settings)
        for settings in invalidSettings {
            var profile = original; profile.displays[0].settings = settings
            XCTAssertThrowsError(try ProfileMatcher.arguments(profile: profile, displays: [monitor]))
        }
        var invalidVersion = original; invalidVersion.version = 1
        XCTAssertThrowsError(try ProfileMatcher.arguments(profile: invalidVersion, displays: [monitor]))
    }

    func testMainOriginCountsLeadersAndRejectsInvalidExtendedLayout() throws {
        XCTAssertThrowsError(try ProfileBuilder.capture(name: "Desk", displays: [display(x: 2560)]))
        XCTAssertThrowsError(try ProfileBuilder.capture(name: "Desk", displays: [display(), display(2, serial: "RIGHT")]))
        var follower = display(2, serial: "RIGHT")
        follower.mirrorPrimaryID = 1
        XCTAssertNoThrow(try ProfileBuilder.capture(name: "Desk", displays: [display(), follower]))
    }
}
