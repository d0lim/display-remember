import Foundation
import ServiceManagement
import XCTest
@testable import DisplayRememberAppSupport

final class PreferencesTests: XCTestCase {
    @MainActor
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suite = "display-remember.preferences-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    @MainActor
    func testMissingPreferencesUseSafeDefaultsWithoutSelectingAProfile() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.language, .system)
        XCTAssertEqual(preferences.pollingInterval, 5)
        XCTAssertFalse(preferences.autoRestore)
        XCTAssertNil(preferences.selectedProfileName)
        XCTAssertNil(defaults.object(forKey: AppPreferences.Keys.selectedProfileName))
    }

    @MainActor
    func testChangesPersistImmediatelyAndReloadAcrossInstances() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.language = .korean
        preferences.pollingInterval = 30
        preferences.autoRestore = true
        preferences.selectedProfileName = "Desk.json"
        XCTAssertEqual(defaults.string(forKey: AppPreferences.Keys.language), "ko")
        XCTAssertEqual(defaults.double(forKey: AppPreferences.Keys.pollingInterval), 30)
        XCTAssertTrue(defaults.bool(forKey: AppPreferences.Keys.autoRestore))
        XCTAssertEqual(defaults.string(forKey: AppPreferences.Keys.selectedProfileName), "Desk.json")

        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let restored = AppPreferences(defaults: secondDefaults)
        XCTAssertEqual(restored.language, .korean)
        XCTAssertEqual(restored.pollingInterval, 30)
        XCTAssertTrue(restored.autoRestore)
        XCTAssertEqual(restored.selectedProfileName, "Desk.json")
    }

    @MainActor
    func testInvalidPersistedLanguageIntervalAndBooleanAreRepaired() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unsupported-language", forKey: AppPreferences.Keys.language)
        defaults.set(7, forKey: AppPreferences.Keys.pollingInterval)
        defaults.set("yes", forKey: AppPreferences.Keys.autoRestore)
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.language, .system)
        XCTAssertEqual(preferences.pollingInterval, 5)
        XCTAssertFalse(preferences.autoRestore)
        XCTAssertEqual(defaults.string(forKey: AppPreferences.Keys.language), "system")
        XCTAssertEqual(defaults.double(forKey: AppPreferences.Keys.pollingInterval), 5)
        XCTAssertFalse(defaults.bool(forKey: AppPreferences.Keys.autoRestore))
    }

    @MainActor
    func testPollingIntervalOnlyAcceptsSupportedValues() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(AppPreferences.pollingIntervals, [2, 5, 10, 30, 60])
        for interval in AppPreferences.pollingIntervals {
            preferences.pollingInterval = interval
            XCTAssertEqual(preferences.pollingInterval, interval)
            XCTAssertEqual(defaults.double(forKey: AppPreferences.Keys.pollingInterval), interval)
        }
        for invalid in [-1, 0, 3, 5.5, Double.infinity, -Double.infinity, Double.nan] {
            preferences.pollingInterval = invalid
            XCTAssertEqual(preferences.pollingInterval, 5)
            XCTAssertEqual(defaults.double(forKey: AppPreferences.Keys.pollingInterval), 5)
        }
    }

    @MainActor
    func testWronglyTypedPersistedIntervalsDoNotGetCoerced() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        for invalid: Any in ["30", true, [10]] {
            defaults.set(invalid, forKey: AppPreferences.Keys.pollingInterval)
            XCTAssertEqual(AppPreferences(defaults: defaults).pollingInterval, 5)
        }
    }

    @MainActor
    func testInvalidStoredProfilePathsAreRemovedWithoutChoosingAFallback() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppPreferences.Keys.autoRestore)
        for invalid in ["/tmp/Desk.json", "../Desk.json", "Folder/Desk.json", ".json", " .json", "..json", "...json", "Desk", "Desk.JSON", "Desk.json\0", "Desk\0.json"] {
            defaults.set(invalid, forKey: AppPreferences.Keys.selectedProfileName)
            let preferences = AppPreferences(defaults: defaults)
            XCTAssertNil(preferences.selectedProfileName, invalid)
            XCTAssertNil(defaults.object(forKey: AppPreferences.Keys.selectedProfileName), invalid)
            XCTAssertTrue(preferences.autoRestore, "AppModel must gate restoration on an explicit valid profile; preferences do not select one.")
        }
    }

    @MainActor
    func testLegalMacProfileFilenamesPersistAndReloadWithoutChanges() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        for filename in ["Folder\\Desk.json", "file:Desk.json", "C:\\Desk.json", "Office\nDesk.json", "Office\tDesk.json"] {
            preferences.selectedProfileName = filename
            XCTAssertEqual(preferences.selectedProfileName, filename)
            XCTAssertEqual(defaults.string(forKey: AppPreferences.Keys.selectedProfileName), filename)
            XCTAssertEqual(AppPreferences(defaults: defaults).selectedProfileName, filename)
        }
    }

    @MainActor
    func testProfileChangesPersistOnlyBasenamesAndNilClearsTheKey() async throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.selectedProfileName = "Office Desk.json"
        XCTAssertEqual(preferences.selectedProfileName, "Office Desk.json")
        XCTAssertEqual(defaults.string(forKey: AppPreferences.Keys.selectedProfileName), "Office Desk.json")
        preferences.selectedProfileName = "../../Other.json"
        XCTAssertNil(preferences.selectedProfileName)
        XCTAssertNil(defaults.object(forKey: AppPreferences.Keys.selectedProfileName))
        preferences.selectedProfileName = "Desk.json"
        preferences.selectedProfileName = nil
        XCTAssertNil(defaults.object(forKey: AppPreferences.Keys.selectedProfileName))
    }

    @MainActor
    func testMemoryOnlyInstancesAreIndependent() async {
        let first = AppPreferences(defaults: nil)
        first.language = .english
        first.pollingInterval = 60
        first.autoRestore = true
        first.selectedProfileName = "Memory.json"
        let second = AppPreferences(defaults: nil)
        XCTAssertEqual(first.selectedProfileName, "Memory.json")
        XCTAssertEqual(second.language, .system)
        XCTAssertEqual(second.pollingInterval, 5)
        XCTAssertFalse(second.autoRestore)
        XCTAssertNil(second.selectedProfileName)
    }

    func testLanguageRawValuesAndIdentifiersAreStable() {
        XCTAssertEqual(AppLanguage.allCases.map(\.rawValue), ["system", "en", "ko"])
        XCTAssertEqual(AppLanguage.allCases.map(\.id), ["system", "en", "ko"])
        XCTAssertNil(AppLanguage(rawValue: "unsupported"))
    }

    @MainActor
    func testDisabledLoginIntegrationNeverRegistersOrOpensSettings() async {
        let controller = LoginItemController(allowIntegration: false)
        XCTAssertEqual(controller.status, .unavailable)
        controller.refresh()
        controller.openSystemSettings()
        XCTAssertThrowsError(try controller.setEnabled(true))
        XCTAssertThrowsError(try controller.setEnabled(false))
        XCTAssertEqual(controller.status, .unavailable)
    }

    @MainActor
    func testLoginStatusMappingDoesNotAccessOperatingSystemState() async {
        XCTAssertEqual(LoginItemController.mappedStatus(.notRegistered), .notRegistered)
        XCTAssertEqual(LoginItemController.mappedStatus(.enabled), .enabled)
        XCTAssertEqual(LoginItemController.mappedStatus(.requiresApproval), .requiresApproval)
    }

    @MainActor
    func testPreviouslyUnseenLoginItemCanBeRegisteredByTheUser() async {
        XCTAssertEqual(LoginItemController.mappedStatus(.notFound), .notRegistered)
    }
}
