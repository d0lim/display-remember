import AppKit
import SwiftUI
import DisplayRememberAppSupport

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @ObservedObject private var loginItem: LoginItemController
    @State private var loginError: String?
    @State private var showLoginError = false

    init(model: AppModel) {
        self.model = model
        preferences = model.preferences
        loginItem = model.loginItem
    }

    private var l10n: AppLocalizer { model.localizer }
    private var loginRequested: Bool {
        loginItem.status == .enabled || loginItem.status == .requiresApproval
    }
    private var loginStatus: String {
        switch loginItem.status {
        case .notRegistered: return l10n.text("Not enabled")
        case .enabled: return l10n.text("Enabled")
        case .requiresApproval: return l10n.text("Approve this app in System Settings to finish enabling login launch.")
        case .unavailable: return l10n.text("Available when running the installed app.")
        }
    }

    var body: some View {
        Form {
            Section {
                Picker(l10n.text("Language"), selection: $preferences.language) {
                    Text(l10n.text("System")).tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.english)
                    Text("한국어").tag(AppLanguage.korean)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(l10n.text("Launch at login"), isOn: Binding(
                        get: { loginRequested },
                        set: { requested in
                            do { try loginItem.setEnabled(requested) }
                            catch {
                                loginError = error.localizedDescription
                                showLoginError = true
                            }
                        }
                    ))
                    .disabled(loginItem.status == .unavailable)
                    Text(loginStatus).font(.caption).foregroundStyle(.secondary)
                    Text(l10n.text("Starts in the menu bar without opening a window."))
                        .font(.caption).foregroundStyle(.secondary)
                    if loginItem.status == .requiresApproval {
                        Button(l10n.text("Open Login Items Settings")) { loginItem.openSystemSettings() }
                    }
                }
            } header: {
                Text(l10n.text("General"))
            }

            Section {
                Toggle(l10n.text("Restore after reconnect or wake"), isOn: $model.autoRestore)
                    .disabled(model.selectedProfile == nil)
                Text(l10n.text("Uses the selected saved layout. Choose a layout in the main window."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(l10n.text("Check interval"), selection: $preferences.pollingInterval) {
                    ForEach(AppPreferences.pollingIntervals, id: \.self) { interval in
                        Text(l10n.text(interval == 5 ? "%d seconds (default)" : "%d seconds", Int(interval)))
                            .tag(interval)
                    }
                }
                Text(l10n.text("Two unchanged checks are required before restoring. The default interval is 5 seconds."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(l10n.text("Wake and display changes trigger a refresh. Restore attempts are at least 30 seconds apart."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text(l10n.text("Automatic restore"))
            }

            if let loginError {
                Section {
                    DisclosureGroup(l10n.text("Operation details")) {
                        Text(loginError).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 500, idealWidth: 560, minHeight: 480, idealHeight: 550)
        .environment(\.locale, model.locale)
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
        .alert(l10n.text("Could Not Update Login Items"), isPresented: $showLoginError) {
            Button(l10n.text("OK")) {}
        } message: {
            Text(l10n.text("Try again or manage login items in System Settings."))
        }
    }
}

/// SettingsLink supports current macOS; the native Settings action keeps macOS 13 working.
struct AppSettingsButton: View {
    let localizer: AppLocalizer
    var iconOnly = true

    var body: some View {
        Group {
            if #available(macOS 14, *) {
                SettingsLink { label }
            } else {
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    NSApp.activate(ignoringOtherApps: true)
                } label: { label }
            }
        }
        .accessibilityLabel(localizer.text("Settings…"))
        .help(localizer.text("Language, login launch, and automatic restore"))
    }

    @ViewBuilder
    private var label: some View {
        if iconOnly { Image(systemName: "gearshape") }
        else { Text(localizer.text("Settings…")) }
    }
}
