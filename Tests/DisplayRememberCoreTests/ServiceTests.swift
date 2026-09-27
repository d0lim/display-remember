import Foundation
import XCTest
@testable import DisplayRememberCore

final class ServiceTests: XCTestCase {
    private func display() -> DisplaySnapshot {
        DisplaySnapshot(id: 3, uuid: "fixture", name: "Fixture",
            identity: HardwareIdentity(vendor: 1, product: 2, serialText: "UNIQUE-3"),
            settings: DisplaySettings(width: 1920, height: 1080, refreshRate: 60))
    }

    func testCancellationIsCheckedAfterTheFinalSnapshotAndBeforeEngineExecution() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("engine")
        let marker = directory.appendingPathComponent("ran")
        try "#!/bin/sh\nprintf ran > '\(marker.path)'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let current = [display()]
        var cancelled = false
        let service = DisplayService(engine: try DisplayPlacerEngine(executableURL: executable)) {
            cancelled = true
            return current
        }
        XCTAssertThrowsError(try service.applyArguments(["id:3 degree:90"], expected: current, shouldProceed: { !cancelled }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testChangedSnapshotStopsManualExecution() throws {
        let engine = try DisplayPlacerEngine(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let expected = [display()]
        var changed = display()
        changed.id = 71
        let service = DisplayService(engine: engine, inventory: { [changed] })
        XCTAssertThrowsError(try service.applyArguments(["id:3 degree:90"], expected: expected)) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed before applying"))
        }
    }

    func testAlreadyMatchingProfileNeverCallsEngine() throws {
        let current = [display()]
        let profile = try ProfileBuilder.capture(name: "Desk", displays: current)
        let service = DisplayService(engine: try DisplayPlacerEngine(executableURL: URL(fileURLWithPath: "/usr/bin/false")), inventory: { current })
        XCTAssertNoThrow(try service.apply(profile))
    }

    func testAlreadyMatchingManualSettingsNeverCallEngine() throws {
        let current = [display()]
        let service = DisplayService(engine: try DisplayPlacerEngine(executableURL: URL(fileURLWithPath: "/usr/bin/false")), inventory: { current })
        XCTAssertNoThrow(try service.applyManual(displayID: 3, settings: current[0].settings,
            mirrorPrimaryID: nil, makeMain: false, expected: current))
    }
}
