import AppKit
import Combine
import Foundation
import DisplayRememberCore

private final class RestoreEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func invalidate() { lock.lock(); value &+= 1; lock.unlock() }
    func current() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
    func isCurrent(_ candidate: UInt64) -> Bool { current() == candidate }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var displays: [DisplaySnapshot] = []
    @Published var selectedID: UInt32?
    @Published var profiles: [URL] = []
    @Published var selectedProfile: URL? {
        didSet { restoreEpoch.invalidate(); previous = nil }
    }
    @Published var status = "Checking displays…"
    @Published var detail = ""
    @Published var busy = false
    @Published var autoRestore = false {
        didSet { restoreEpoch.invalidate(); previous = nil }
    }
    @Published var error: String?
    private let worker = DispatchQueue(label: "app.display-remember.operations")
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var previous: [DisplaySnapshot]?
    private var lastRestore = Date.distantPast
    private let restoreEpoch = RestoreEpoch()
    private let shouldLoadSavedProfiles: Bool

    var profileDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("display-remember/Profiles", isDirectory: true)
    }

    init(initialDisplays: [DisplaySnapshot]? = nil, interactive: Bool = true, loadSavedProfiles: Bool = true) {
        shouldLoadSavedProfiles = loadSavedProfiles
        reloadProfiles()
        if let initialDisplays {
            displays = initialDisplays
            selectedID = initialDisplays.first?.id
            status = "\(initialDisplays.count) display\(initialDisplays.count == 1 ? "" : "s") connected"
        }
        guard interactive else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAutomatically() }
        }
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
                Task { @MainActor in self?.refresh() }
            })
    }

    func reloadProfiles() {
        guard shouldLoadSavedProfiles else { return }
        profiles = ((try? FileManager.default.contentsOfDirectory(at: profileDirectory,
            includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        if selectedProfile == nil { selectedProfile = profiles.first }
    }

    private func perform(selectOnSuccess: URL? = nil, _ operation: @escaping (DisplayService) throws -> ([DisplaySnapshot], String, String)) {
        guard !busy else { return }
        busy = true
        worker.async { [weak self] in
            do {
                let result = try operation(DisplayService())
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.displays = result.0
                    if !result.0.contains(where: { $0.id == self.selectedID }) { self.selectedID = result.0.first?.id }
                    self.status = result.1
                    self.detail = result.2
                    self.busy = false
                    self.reloadProfiles()
                    if let selectOnSuccess { self.selectedProfile = selectOnSuccess }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.status = error.localizedDescription
                    self?.error = error.localizedDescription
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
            return (displays, "\(displays.count) display\(displays.count == 1 ? "" : "s") connected", "")
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
            return (try service.inventory(), "Saved “\(label)”", url.path)
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
            return (try service.inventory(), "Layout imported", destination.path)
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
            return (try service.inventory(), execute ? "Layout restored and verified" : "Preview only · Display settings are unchanged", DisplayService.preview(plan))
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
                status = "Make your changes in System Settings, then save the layout here. Auto-restore is off."
                return
            }
        }
        error = "Could not open Displays settings. Open Apple menu → System Settings → Displays. Auto-restore is off."
    }

    func showProfiles() {
        do {
            try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(profileDirectory)
        } catch { self.error = error.localizedDescription }
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
                    self?.status = shouldRestore ? "Saved layout restored automatically" : matches ? "Your saved layout is in place" : "Waiting for displays to settle"
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
                    self?.status = "Auto-restore waiting: \(error.localizedDescription)"
                    self?.busy = false
                }
            }
        }
    }
}
