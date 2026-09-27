import AppKit
import Combine
import Foundation
import DisplayRememberCore
import DisplayRememberAppSupport

private struct AppMessage {
    let key: String
    let arguments: [CVarArg]
    init(_ key: String, _ arguments: CVarArg...) {
        self.key = key
        self.arguments = arguments
    }
}

private final class RestoreEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func invalidate() { lock.lock(); value &+= 1; lock.unlock() }
    func current() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func isCurrent(_ candidate: UInt64) -> Bool { current() == candidate }
}

@MainActor
final class AppModel: ObservableObject {
    let preferences: AppPreferences
    let loginItem: LoginItemController
    @Published var displays: [DisplaySnapshot] = []
    @Published var selectedID: UInt32?
    @Published var profiles: [URL] = []
    @Published var selectedProfile: URL? {
        didSet {
            restoreEpoch.invalidate()
            previous = nil
            preferences.selectedProfileName = selectedProfile?.lastPathComponent
            if selectedProfile == nil { autoRestore = false }
        }
    }
    @Published private var message = AppMessage("Checking displays…")
    @Published var detail = ""
    @Published var busy = false
    @Published var autoRestore = false {
        didSet {
            restoreEpoch.invalidate()
            previous = nil
            preferences.autoRestore = autoRestore
            scheduleTimer()
        }
    }
    @Published private var errorKey: String?
    var localizer: AppLocalizer { AppLocalizer(language: preferences.language) }
    var locale: Locale { localizer.locale }
    var status: String { localizer.format(message.key, arguments: message.arguments) }
    var error: String? {
        get { errorKey.map { localizer.text($0) } }
        set { errorKey = newValue }
    }
    private let worker = DispatchQueue(label: "app.display-remember.operations")
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var previous: [DisplaySnapshot]?
    private var lastRestore = Date.distantPast
    private let restoreEpoch = RestoreEpoch()
    private let shouldLoadSavedProfiles: Bool
    private let interactive: Bool
    private let profileDirectoryOverride: URL?
    private var subscriptions = Set<AnyCancellable>()

    var profileDirectory: URL {
        profileDirectoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("display-remember/Profiles", isDirectory: true)
    }

    init(initialDisplays: [DisplaySnapshot]? = nil, interactive: Bool = true, loadSavedProfiles: Bool = true,
         preferences: AppPreferences? = nil, loginItem: LoginItemController? = nil, profileDirectory: URL? = nil) {
        self.preferences = preferences ?? AppPreferences(defaults: interactive ? .standard : nil)
        self.loginItem = loginItem ?? LoginItemController(allowIntegration: interactive)
        self.interactive = interactive
        profileDirectoryOverride = profileDirectory
        shouldLoadSavedProfiles = loadSavedProfiles
        autoRestore = self.preferences.autoRestore
        reloadProfiles()
        if let initialDisplays {
            displays = initialDisplays
            selectedID = initialDisplays.first?.id
            message = Self.connectedMessage(initialDisplays.count)
        }
        self.preferences.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        self.preferences.$pollingInterval.dropFirst().removeDuplicates().sink { [weak self] interval in
            self?.restoreEpoch.invalidate()
            self?.previous = nil
            self?.scheduleTimer(interval: interval)
        }.store(in: &subscriptions)
        guard interactive else { return }
        refresh()
        scheduleTimer()
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.previous = nil; self?.refresh() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.previous = nil; self?.refresh() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.loginItem.refresh(); self?.refresh() }
            })
    }

    deinit {
        restoreEpoch.invalidate()
        timer?.invalidate()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setStatus(_ key: String) { message = AppMessage(key) }

    private static func connectedMessage(_ count: Int) -> AppMessage {
        AppMessage(count == 1 ? "%d display connected" : "%d displays connected", count)
    }

    private func scheduleTimer(interval: Double? = nil) {
        timer?.invalidate()
        timer = nil
        guard interactive, autoRestore else { return }
        let requested = interval ?? preferences.pollingInterval
        let safeInterval = AppPreferences.pollingIntervals.contains(requested) ? requested : 5
        timer = Timer.scheduledTimer(withTimeInterval: safeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAutomatically() }
        }
        timer?.tolerance = min(1, safeInterval * 0.1)
    }

    func reloadProfiles() {
        guard shouldLoadSavedProfiles else { return }
        profiles = ((try? FileManager.default.contentsOfDirectory(at: profileDirectory,
            includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let name = selectedProfile?.lastPathComponent ?? preferences.selectedProfileName {
            let selected = profiles.first { $0.lastPathComponent == name }
            if selected != selectedProfile { selectedProfile = selected }
            if selected == nil {
                autoRestore = false
                preferences.selectedProfileName = nil
                message = AppMessage("The saved layout is no longer available. Choose a layout to enable auto-restore.")
            }
        } else if selectedProfile == nil {
            // Never resume restoration with a different profile just because it sorts first.
            autoRestore = false
            selectedProfile = profiles.first
        }
    }

    private func perform(selectOnSuccess: URL? = nil, _ operation: @escaping (DisplayService) throws -> ([DisplaySnapshot], AppMessage, String)) {
        guard !busy else { return }
        busy = true
        worker.async { [weak self] in
            do {
                let result = try operation(DisplayService())
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.displays = result.0
                    if !result.0.contains(where: { $0.id == self.selectedID }) { self.selectedID = result.0.first?.id }
                    self.message = result.1
                    self.detail = result.2
                    self.busy = false
                    self.reloadProfiles()
                    if let selectOnSuccess { self.selectedProfile = selectOnSuccess }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.message = AppMessage("Could not complete the operation. See operation details.")
                    self?.error = "Could not complete the operation. See operation details."
                    self?.detail = error.localizedDescription
                    self?.busy = false
                }
            }
        }
    }

    func refresh() {
        restoreEpoch.invalidate()
        previous = nil
        perform { service in
            let displays = try service.inventory()
            return (displays, Self.connectedMessage(displays.count), "")
        }
    }

    func save(name: String) {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { error = "Enter a layout name."; return }
        let safeName = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = profileDirectory.appendingPathComponent(safeName + ".json")
        perform(selectOnSuccess: url) { service in
            let profile = try service.capture(name: label)
            try ProfileStorage.write(profile, to: url)
            return (try service.inventory(), AppMessage("Saved “%@”", label), url.path)
        }
    }

    func importProfile() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let destination = profileDirectory.appendingPathComponent(source.lastPathComponent)
        perform(selectOnSuccess: destination) { service in
            let profile = try ProfileStorage.read(source)
            _ = try ProfileMatcher.arguments(profile: profile, displays: service.inventory())
            try ProfileStorage.write(profile, to: destination)
            return (try service.inventory(), AppMessage("Layout imported"), destination.path)
        }
    }

    func profileAction(execute: Bool) {
        guard let url = selectedProfile else { return }
        if execute { previous = nil }
        perform { service in
            let profile = try ProfileStorage.read(url)
            let displays = try service.inventory()
            let plan = try ProfileMatcher.arguments(profile: profile, displays: displays)
            if execute { try service.apply(profile) }
            return (try service.inventory(), AppMessage(execute ? "Layout restored and verified" : "Preview only · Display settings are unchanged"), DisplayService.preview(plan))
        }
    }

    func openDisplaySettings() {
        guard !busy else { return }
        // A saved profile must not undo the changes being made in System Settings.
        autoRestore = false
        let workspace = NSWorkspace.shared
        let paneURLs = [
            "x-apple.systempreferences:com.apple.Displays-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.displays"
        ]
        for address in paneURLs {
            if let url = URL(string: address), workspace.open(url) {
                setStatus("Make your changes in System Settings, then save the layout here. Auto-restore is off.")
                return
            }
        }
        error = "Could not open Displays settings. Open Apple menu → System Settings → Displays. Auto-restore is off."
    }

    func showProfiles() {
        do {
            try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(profileDirectory)
        } catch {
            self.error = "Could not complete the operation. See operation details."
            detail = error.localizedDescription
        }
    }

    private func checkAutomatically() {
        guard autoRestore, !busy, let url = selectedProfile else { return }
        busy = true
        let previousSnapshot = previous
        let canRestore = Date().timeIntervalSince(lastRestore) >= 30
        let epoch = restoreEpoch
        let generation = epoch.current()
        worker.async { [weak self] in
            do {
                let service = try DisplayService()
                let profile = try ProfileStorage.read(url)
                let current = try service.inventory()
                _ = try ProfileMatcher.arguments(profile: profile, displays: current)
                let matches = try ProfileMatcher.matches(profile: profile, displays: current)
                let shouldRestore = !matches && current == previousSnapshot && canRestore
                if shouldRestore {
                    DispatchQueue.main.async { self?.lastRestore = Date() }
                    try service.apply(profile, shouldProceed: { epoch.isCurrent(generation) })
                }
                let final = shouldRestore ? try service.inventory() : current
                DispatchQueue.main.async {
                    guard epoch.isCurrent(generation) else {
                        self?.busy = false
                        self?.refresh()
                        return
                    }
                    self?.previous = final
                    self?.displays = final
                    self?.setStatus(shouldRestore ? "Saved layout restored automatically" : matches ? "Your saved layout is in place" : "Waiting for displays to settle")
                    self?.busy = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard epoch.isCurrent(generation) else {
                        self?.busy = false
                        self?.refresh()
                        return
                    }
                    self?.previous = nil
                    self?.setStatus("Auto-restore is waiting. See operation details.")
                    self?.detail = error.localizedDescription
                    self?.busy = false
                }
            }
        }
    }
}
