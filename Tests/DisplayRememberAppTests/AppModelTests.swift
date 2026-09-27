import XCTest
import DisplayRememberAppSupport
@testable import DisplayRememberApp

final class AppModelTests: XCTestCase {
    @MainActor
    func testRelaunchKeepsExplicitProfileAndAutoRestore() throws {
        let directory = try makeProfiles(["A.json", "Desk.json"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = AppPreferences(defaults: nil)
        preferences.selectedProfileName = "Desk.json"
        preferences.autoRestore = true

        let model = AppModel(interactive: false, preferences: preferences, profileDirectory: directory)
        XCTAssertEqual(model.selectedProfile?.lastPathComponent, "Desk.json")
        XCTAssertTrue(model.autoRestore)
        model.selectedProfile = directory.appendingPathComponent("A.json")
        model.autoRestore = false

        let relaunched = AppModel(interactive: false, preferences: preferences, profileDirectory: directory)
        XCTAssertEqual(relaunched.selectedProfile?.lastPathComponent, "A.json")
        XCTAssertFalse(relaunched.autoRestore)
    }

    @MainActor
    func testMissingSavedProfileDisablesRestorationWithoutSelectingAnother() throws {
        let directory = try makeProfiles(["Other.json"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = AppPreferences(defaults: nil)
        preferences.selectedProfileName = "Missing.json"
        preferences.autoRestore = true

        let model = AppModel(interactive: false, preferences: preferences, profileDirectory: directory)
        XCTAssertNil(model.selectedProfile)
        XCTAssertFalse(model.autoRestore)
        XCTAssertFalse(preferences.autoRestore)
        XCTAssertNil(preferences.selectedProfileName)
    }

    @MainActor
    func testMissingSelectionNeverEnablesRestorationForFirstProfile() throws {
        let directory = try makeProfiles(["First.json"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = AppPreferences(defaults: nil)
        preferences.autoRestore = true
        let model = AppModel(interactive: false, preferences: preferences, profileDirectory: directory)
        XCTAssertEqual(model.selectedProfile?.lastPathComponent, "First.json")
        XCTAssertFalse(model.autoRestore)
        XCTAssertFalse(preferences.autoRestore)
    }

    @MainActor
    func testRemovingSelectedProfileStopsRestoration() throws {
        let directory = try makeProfiles(["Desk.json", "Other.json"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let preferences = AppPreferences(defaults: nil)
        preferences.selectedProfileName = "Desk.json"
        preferences.autoRestore = true
        let model = AppModel(interactive: false, preferences: preferences, profileDirectory: directory)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Desk.json"))
        model.reloadProfiles()
        XCTAssertNil(model.selectedProfile)
        XCTAssertFalse(model.autoRestore)
    }

    @MainActor
    func testLanguageChangeAlsoUpdatesExistingStatusAndError() {
        let preferences = AppPreferences(defaults: nil)
        preferences.language = .english
        let model = AppModel(interactive: false, loadSavedProfiles: false, preferences: preferences)
        model.setStatus("Your saved layout is in place")
        model.error = "Enter a layout name."
        let englishStatus = model.status
        let englishError = model.error
        preferences.language = .korean
        XCTAssertNotEqual(model.status, englishStatus)
        XCTAssertNotEqual(model.error, englishError)
        XCTAssertEqual(model.locale.languageCode, "ko")
    }

    private func makeProfiles(_ names: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names { try Data("{}".utf8).write(to: directory.appendingPathComponent(name)) }
        return directory
    }
}
