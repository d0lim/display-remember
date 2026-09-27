import AppKit
import Combine
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
    private var dockPreferenceSubscription: AnyCancellable?
    private var hasFinishedLaunching = false
    private let applyActivationPolicy: (NSApplication.ActivationPolicy) -> Void
    private let presentMainWindow: ((AppModel) -> Void)?

    override convenience init() {
        self.init(applyActivationPolicy: { NSApp.setActivationPolicy($0) })
    }

    /// Tests can capture policy and window requests without changing the running application.
    init(applyActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Void,
         presentMainWindow: ((AppModel) -> Void)? = nil) {
        self.applyActivationPolicy = applyActivationPolicy
        self.presentMainWindow = presentMainWindow
        super.init()
    }

    func configure(model: AppModel) {
        dockPreferenceSubscription = nil
        self.model = model
        if hasFinishedLaunching { observeDockPreference() }
    }

    private func observeDockPreference() {
        guard let model else { return }
        dockPreferenceSubscription = model.preferences.$hideDockIcon.removeDuplicates().sink { [weak self] hidden in
            self?.applyDockPreference(hidden)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // currentAppleEvent is valid only during its handler, before async work.
        finishLaunching(isLoginItem: AppLaunch.isLoginItem(event: NSAppleEventManager.shared().currentAppleEvent))
    }

    func finishLaunching(isLoginItem: Bool) {
        // SwiftUI configures the delegate before NSApp exists; subscribe only once launch is complete.
        hasFinishedLaunching = true
        observeDockPreference()
        if !isLoginItem { showWindow() }
    }

    private func applyDockPreference(_ hidden: Bool) {
        applyActivationPolicy(hidden ? .accessory : .regular)
    }

    func showWindow() {
        guard hasFinishedLaunching, let model else { return }
        applyDockPreference(model.preferences.hideDockIcon)
        if let presentMainWindow {
            presentMainWindow(model)
            return
        }
        if windowController == nil {
            let hostingController = NSHostingController(rootView: MainWindowContent(model: model))
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Display Remember"
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
