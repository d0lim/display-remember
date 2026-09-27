import Foundation
import XCTest
@testable import DisplayRememberCore

final class EngineTests: XCTestCase {
    private func withDirectory(body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func writeExecutable(at script: URL, source: String = "exit 0\n") throws {
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + source).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    private func withExecutable(_ source: String, body: (URL) throws -> Void) throws {
        try withDirectory { directory in
            let script = directory.appendingPathComponent("engine fixture")
            try writeExecutable(at: script, source: source)
            try body(script)
        }
    }

    func testSymlinkedPackagedCLIResolvesItsBundledHelper() throws {
        try withDirectory { directory in
            let app = directory.appendingPathComponent("display-remember.app")
            let cli = app.appendingPathComponent("Contents/MacOS/display-remember")
            let helper = app.appendingPathComponent("Contents/Helpers/displayplacer")
            let bin = directory.appendingPathComponent("bin")
            let link = bin.appendingPathComponent("display-remember")
            try writeExecutable(at: cli)
            try writeExecutable(at: helper)
            // A nearby standalone helper must not take priority over the app.
            try writeExecutable(at: bin.appendingPathComponent("displayplacer"))
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)

            let resolved = try DisplayPlacerEngine.resolveExecutable(
                bundleURL: bin, applicationExecutableURL: link, currentDirectoryURL: directory
            )
            XCTAssertEqual(resolved, helper.resolvingSymlinksInPath())
        }
    }

    func testSymlinkedPackagedCLIWithMissingHelperCannotUseOtherCopies() throws {
        try withDirectory { directory in
            let app = directory.appendingPathComponent("display-remember.app")
            let cli = app.appendingPathComponent("Contents/MacOS/display-remember")
            let bin = directory.appendingPathComponent("bin")
            let link = bin.appendingPathComponent("display-remember")
            try writeExecutable(at: cli)
            try writeExecutable(at: cli.deletingLastPathComponent().appendingPathComponent("displayplacer"))
            try writeExecutable(at: bin.appendingPathComponent("displayplacer"))
            try writeExecutable(at: directory.appendingPathComponent(".build/helpers/displayplacer"))
            try "// fixture".write(to: directory.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)

            XCTAssertThrowsError(try DisplayPlacerEngine.resolveExecutable(
                bundleURL: bin, applicationExecutableURL: link, currentDirectoryURL: directory
            )) { error in
                guard case DisplayPlacerEngineError.unavailable = error else {
                    return XCTFail("Expected missing bundled helper, received \(error)")
                }
            }
        }
    }

    func testStandaloneBuildDiscoveryUsesResolvedExecutableAncestry() throws {
        try withDirectory { directory in
            let cli = directory.appendingPathComponent(".build/arm64-apple-macosx/release/display-remember")
            let helper = directory.appendingPathComponent(".build/helpers/displayplacer")
            let bin = directory.appendingPathComponent("bin")
            let link = bin.appendingPathComponent("display-remember")
            try writeExecutable(at: cli)
            try writeExecutable(at: helper)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cli)

            let resolved = try DisplayPlacerEngine.resolveExecutable(
                bundleURL: bin, applicationExecutableURL: link, currentDirectoryURL: bin
            )
            XCTAssertEqual(resolved, helper.resolvingSymlinksInPath())
        }
    }

    func testArgumentsArePassedLiterallyAndExitStatusIsPreserved() throws {
        try withExecutable("printf '%s\\n' \"$@\"\nprintf 'diagnostic' >&2\nexit 7\n") { url in
            let engine = try DisplayPlacerEngine(executableURL: url)
            let arguments = ["id:41 origin:(0,0)", "$(touch should-never-exist)", "a'b\"c", ""]
            let result = try engine.run(arguments: arguments)
            XCTAssertEqual(result.stdout, arguments.joined(separator: "\n") + "\n")
            XCTAssertEqual(result.stderr, "diagnostic")
            XCTAssertEqual(result.status, 7)
            XCTAssertEqual(engine.executableURL, url.resolvingSymlinksInPath())
        }
    }

    func testBothPipesDrainBeyondPipeCapacityWithoutDeadlock() throws {
        try withExecutable("""
        i=0
        while [ "$i" -lt 8192 ]; do
          printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\\n'
          printf 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210\\n' >&2
          i=$((i + 1))
        done
        """) { url in
            let result = try DisplayPlacerEngine(executableURL: url).run(arguments: [], timeout: 10)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.stdout.utf8.count, 8192 * 65)
            XCTAssertEqual(result.stderr.utf8.count, 8192 * 65)
        }
    }

    func testTimeoutKillsAHelperThatIgnoresTermination() throws {
        try withExecutable("trap '' TERM\nwhile :; do :; done\n") { url in
            let engine = try DisplayPlacerEngine(executableURL: url)
            let started = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try engine.run(arguments: [], timeout: 0.1)) { error in
                guard case DisplayPlacerEngineError.timedOut = error else {
                    return XCTFail("Expected timeout, received \(error)")
                }
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        }
    }

    func testContinuousOutputCannotStarveTimeoutChecks() throws {
        try withExecutable("while :; do printf 'busy\\n'; done\n") { url in
            let engine = try DisplayPlacerEngine(executableURL: url)
            let started = ProcessInfo.processInfo.systemUptime
            XCTAssertThrowsError(try engine.run(arguments: [], timeout: 0.1)) { error in
                guard case DisplayPlacerEngineError.timedOut = error else {
                    return XCTFail("Expected timeout, received \(error)")
                }
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 3)
        }
    }

    func testExplicitMissingExecutableNeverFallsBack() throws {
        XCTAssertThrowsError(try DisplayPlacerEngine(executableURL: URL(fileURLWithPath: "/missing/displayplacer")))
        XCTAssertThrowsError(try DisplayPlacerEngine(executableURL: URL(string: "https://example.com/displayplacer")!))
        XCTAssertThrowsError(try DisplayPlacerEngine(executableURL: FileManager.default.temporaryDirectory))
    }

    func testInvalidRequestsAreRejectedBeforeLaunch() throws {
        let engine = try DisplayPlacerEngine(executableURL: URL(fileURLWithPath: "/usr/bin/true"))
        for timeout in [0, -1, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try engine.run(arguments: [], timeout: timeout))
        }
        XCTAssertThrowsError(try engine.run(arguments: ["bad\0argument"]))
    }
}
