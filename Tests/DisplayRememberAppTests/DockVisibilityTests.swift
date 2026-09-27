import AppKit
import DisplayRememberAppSupport
import XCTest
@testable import DisplayRememberApp

final class DockVisibilityTests: XCTestCase {
    @MainActor
    private func model(preferences: AppPreferences) -> AppModel {
        AppModel(initialDisplays: [], interactive: false, loadSavedProfiles: false, preferences: preferences)
    }

    @MainActor
    func testOrdinaryLaunchAndRepeatedWindowOpeningKeepTheDockHidden() async {
        let preferences = AppPreferences(defaults: nil)
        var policies: [NSApplication.ActivationPolicy] = []
        var windowRequests = 0
        let delegate = AppDelegate(
            applyActivationPolicy: { policies.append($0) },
            presentMainWindow: { _ in windowRequests += 1 }
        )

        delegate.configure(model: model(preferences: preferences))
        XCTAssertTrue(policies.isEmpty)
        XCTAssertEqual(windowRequests, 0)
        delegate.finishLaunching(isLoginItem: false)
        delegate.showWindow()
        XCTAssertEqual(windowRequests, 2)
        XCTAssertEqual(policies, [.accessory, .accessory, .accessory])
    }

    @MainActor
    func testLoginLaunchHonorsBothDockChoicesWithoutOpeningAWindow() async {
        for hidden in [true, false] {
            let preferences = AppPreferences(defaults: nil)
            preferences.hideDockIcon = hidden
            var policies: [NSApplication.ActivationPolicy] = []
            var windowRequests = 0
            let delegate = AppDelegate(
                applyActivationPolicy: { policies.append($0) },
                presentMainWindow: { _ in windowRequests += 1 }
            )

            delegate.configure(model: model(preferences: preferences))
            XCTAssertTrue(policies.isEmpty)
            delegate.finishLaunching(isLoginItem: true)
            XCTAssertEqual(windowRequests, 0)
            XCTAssertEqual(policies, hidden ? [.accessory] : [.regular])
            delegate.showWindow()
            XCTAssertEqual(windowRequests, 1)
            XCTAssertEqual(policies.last, hidden ? .accessory : .regular)
        }
    }

    @MainActor
    func testChangingDockPreferenceAppliesImmediatelyAndSurvivesWindowOpening() async {
        let preferences = AppPreferences(defaults: nil)
        var policies: [NSApplication.ActivationPolicy] = []
        var windowRequests = 0
        let delegate = AppDelegate(
            applyActivationPolicy: { policies.append($0) },
            presentMainWindow: { _ in windowRequests += 1 }
        )
        delegate.configure(model: model(preferences: preferences))
        delegate.finishLaunching(isLoginItem: true)
        preferences.hideDockIcon = false
        XCTAssertEqual(policies, [.accessory, .regular])
        XCTAssertEqual(windowRequests, 0)
        delegate.showWindow()
        XCTAssertEqual(policies.last, .regular)
        preferences.hideDockIcon = true
        XCTAssertEqual(policies.last, .accessory)
        delegate.showWindow()
        XCTAssertEqual(policies.last, .accessory)
        XCTAssertEqual(windowRequests, 2)
    }

    @MainActor
    func testReconfigurationStopsObservingThePreviousPreferences() async {
        let first = AppPreferences(defaults: nil)
        let second = AppPreferences(defaults: nil)
        second.hideDockIcon = false
        var policies: [NSApplication.ActivationPolicy] = []
        let delegate = AppDelegate(applyActivationPolicy: { policies.append($0) }, presentMainWindow: { _ in })
        delegate.configure(model: model(preferences: first))
        delegate.finishLaunching(isLoginItem: true)
        delegate.configure(model: model(preferences: second))
        XCTAssertEqual(policies, [.accessory, .regular])
        first.hideDockIcon = false
        XCTAssertEqual(policies, [.accessory, .regular])
        second.hideDockIcon = true
        XCTAssertEqual(policies, [.accessory, .regular, .accessory])
    }

    @MainActor
    func testPrelaunchConfigurationDoesNotAccessTheApplicationAndUsesLatestPreferenceOnLaunch() async {
        let preferences = AppPreferences(defaults: nil)
        var policies: [NSApplication.ActivationPolicy] = []
        var windowRequests = 0
        let delegate = AppDelegate(
            applyActivationPolicy: { policies.append($0) },
            presentMainWindow: { _ in windowRequests += 1 }
        )

        delegate.configure(model: model(preferences: preferences))
        preferences.hideDockIcon = false
        delegate.showWindow()
        XCTAssertTrue(policies.isEmpty)
        XCTAssertEqual(windowRequests, 0)

        delegate.finishLaunching(isLoginItem: true)
        XCTAssertEqual(policies, [.regular])
        XCTAssertEqual(windowRequests, 0)
    }
}
