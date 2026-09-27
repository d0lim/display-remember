import AppKit
import CoreServices
import SwiftUI

enum AppLaunch {
    /// Inspect synchronously while the launch Apple event is being handled.
    static func isLoginItem(event: NSAppleEventDescriptor?) -> Bool {
        guard let event else { return false }
        return event.eventClass == kCoreEventClass && event.eventID == kAEOpenApplication &&
            event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var windowController: NSWindowController?

    func configure(model: AppModel) {
        self.model = model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // currentAppleEvent is valid only during its handler, before async work.
        if AppLaunch.isLoginItem(event: NSAppleEventManager.shared().currentAppleEvent) {
            NSApp.setActivationPolicy(.accessory)
        } else {
            showWindow()
        }
    }

    func showWindow() {
        guard let model else { return }
        if windowController == nil {
            let hostingController = NSHostingController(rootView: MainWindowContent(model: model))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "display-remember"
            window.identifier = NSUserInterfaceItemIdentifier("display-remember.main")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1080, height: 820))
            window.contentMinSize = NSSize(width: 980, height: 700)
            // A login launch must not restore a previously open main window.
            window.isRestorable = false
            window.isReleasedWhenClosed = false
            window.center()
            windowController = NSWindowController(window: window)
        }
        NSApp.setActivationPolicy(.regular)
        if windowController?.window?.isMiniaturized == true {
            windowController?.window?.deminiaturize(nil)
        }
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        // We already handled reopening the retained main window.
        return false
    }
}

private struct MainWindowContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ContentView(model: model)
            .frame(minWidth: 980, minHeight: 700)
            .tint(Color(red: 0.08, green: 0.55, blue: 0.59))
            .environment(\.locale, model.locale)
    }
}
