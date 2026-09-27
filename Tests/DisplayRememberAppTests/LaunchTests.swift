import AppKit
import CoreServices
import XCTest
@testable import DisplayRememberApp

final class LaunchTests: XCTestCase {
    private func event(
        eventClass: AEEventClass = AEEventClass(kCoreEventClass),
        eventID: AEEventID = AEEventID(kAEOpenApplication),
        launchReason: OSType? = nil
    ) -> NSAppleEventDescriptor {
        let descriptor = NSAppleEventDescriptor(
            eventClass: eventClass, eventID: eventID, targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
        )
        if let launchReason {
            descriptor.setParam(NSAppleEventDescriptor(enumCode: launchReason), forKeyword: AEKeyword(keyAEPropData))
        }
        return descriptor
    }

    func testLoginItemOpenEventIsRecognized() {
        XCTAssertTrue(AppLaunch.isLoginItem(event: event(launchReason: OSType(keyAELaunchedAsLogInItem))))
    }

    func testOrdinaryAndDirectLaunchesOpenTheWindow() {
        XCTAssertFalse(AppLaunch.isLoginItem(event: nil))
        XCTAssertFalse(AppLaunch.isLoginItem(event: event()))
        XCTAssertFalse(AppLaunch.isLoginItem(event: event(launchReason: 0)))
    }

    func testOtherEventTypesCannotBeMistakenForLogin() {
        XCTAssertFalse(AppLaunch.isLoginItem(event: event(
            eventID: AEEventID(kAEReopenApplication), launchReason: OSType(keyAELaunchedAsLogInItem)
        )))
        XCTAssertFalse(AppLaunch.isLoginItem(event: event(
            eventClass: AEEventClass(kInternetEventClass), launchReason: OSType(keyAELaunchedAsLogInItem)
        )))
        XCTAssertFalse(AppLaunch.isLoginItem(event: event(launchReason: OSType(keyAELaunchedAsServiceItem))))
    }

}
