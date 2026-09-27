import AppKit
import SwiftUI
import DisplayRememberCore

@main
struct DisplayRememberApp: App {
    @StateObject private var model: AppModel

    init() {
        // Demo rendering never reads connected hardware or the user's saved profiles.
        // The preview command retains its normal read-only scan for local visual QA.
        if CommandLine.arguments.count == 3,
           ["--render-preview", "--render-demo"].contains(CommandLine.arguments[1]) {
            do {
                let isDemo = CommandLine.arguments[1] == "--render-demo"
                let snapshots: [DisplaySnapshot]
                if isDemo { snapshots = DemoDisplays.snapshots }
                else { snapshots = try DisplayService().inventory() }
                let preview = AppModel(initialDisplays: snapshots, interactive: false, loadSavedProfiles: !isDemo)
                if isDemo {
                    // A fictional in-memory entry makes restore controls visible. No file is read or written.
                    let demoProfile = URL(fileURLWithPath: "/demo/Desk.json")
                    preview.profiles = [demoProfile]
                    preview.selectedProfile = demoProfile
                    preview.autoRestore = true
                    preview.status = "Demo layout · 2 fictional displays"
                }
                let view = ContentView(model: preview).frame(width: 1080, height: 900)
                    .tint(Color(red: 0.08, green: 0.55, blue: 0.59))
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .light)
                    .environment(\.locale, isDemo ? Locale(identifier: "en_US_POSIX") : Locale.current)
                let host = NSHostingView(rootView: view)
                host.frame = NSRect(x: 0, y: 0, width: 1080, height: 900)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw DisplayRememberError("Could not prepare the preview image.")
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    throw DisplayRememberError("Could not encode the preview image.")
                }
                try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Preview error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("display-remember") {
            ContentView(model: model)
                .frame(minWidth: 980, minHeight: 700)
                .tint(Color(red: 0.08, green: 0.55, blue: 0.59))
        }
        .defaultSize(width: 1080, height: 820)
        MenuBarExtra("display-remember", systemImage: "display.2") {
            Text(model.status)
            Button("Refresh Displays") { model.refresh() }
            Button("Open Displays Settings") { model.openDisplaySettings() }
                .disabled(model.busy)
            Button("Restore Saved Layout") { model.profileAction(execute: true) }
                .disabled(model.selectedProfile == nil || model.busy)
            Toggle("Auto-restore", isOn: $model.autoRestore)
                .disabled(model.selectedProfile == nil)
            Divider()
            Button("Show Window") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

private enum DemoDisplays {
    static var snapshots: [DisplaySnapshot] {
        [
            DisplaySnapshot(
                id: 101, uuid: "00000000-0000-0000-0000-000000000101", name: "Studio Display",
                identity: HardwareIdentity(vendor: 4660, product: 1001, serialText: "DEMO-LANDSCAPE"),
                settings: DisplaySettings(width: 2560, height: 1440, refreshRate: 60, scaled: true,
                    x: 0, y: 0, rotation: 0, modeNumber: 1),
                modes: [DisplayMode(number: 1, width: 2560, height: 1440,
                    refreshRate: 60, scaled: true, current: true)]
            ),
            DisplaySnapshot(
                id: 202, uuid: "00000000-0000-0000-0000-000000000202", name: "Portrait Display",
                identity: HardwareIdentity(vendor: 4660, product: 1002, serialText: "DEMO-PORTRAIT"),
                settings: DisplaySettings(width: 1440, height: 2560, refreshRate: 60, scaled: false,
                    x: 2560, y: -560, rotation: 90, modeNumber: 2),
                modes: [DisplayMode(number: 2, width: 1440, height: 2560,
                    refreshRate: 60, scaled: false, current: true)]
            ),
        ]
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var profileName = "Desk"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                MonitorSidebar(model: model)
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 280)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        SystemSettingsCard(model: model)
                        RememberLayoutCard(model: model, profileName: $profileName)
                        if let display = model.displays.first(where: { $0.id == model.selectedID }) {
                            DisplayDetails(display: display, displays: model.displays)
                        }
                        if !model.detail.isEmpty {
                            DisclosureGroup("Operation details") {
                                Text(model.detail)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 8)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                        }
                    }
                    .padding(22)
                }
                .frame(minWidth: 670)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Could Not Complete the Operation", isPresented: Binding(
            get: { model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            BrandIcon().frame(width: 48, height: 48).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("display-remember")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("Set it up in macOS. Remember it here.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Checking display information")
            }
            Button { model.refresh() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.busy)
            .help("Refresh connected displays and their layout")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Circle().fill(model.autoRestore ? Color.teal : Color.secondary)
                .frame(width: 6, height: 6).accessibilityHidden(true)
            Text(model.status).font(.caption).lineLimit(2)
            Spacer(minLength: 16)
            Text(model.autoRestore ? "Auto-restore on" : "Auto-restore off")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }
}

private struct BrandIcon: View {
    var body: some View {
        if let image = NSImage(named: "AppIcon") {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "display.2")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.tint)
        }
    }
}

private struct MonitorSidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Connected displays").font(.headline)
                Spacer()
                Text("\(model.displays.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 18).padding(.top, 22)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(model.displays, id: \.id) { display in
                        monitorButton(display)
                    }
                }
                .padding(.horizontal, 10)
            }
            Label("Select a display to view its current setup.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(18)
        }
    }

    private func monitorButton(_ display: DisplaySnapshot) -> some View {
        let selected = model.selectedID == display.id
        return Button { model.selectedID = display.id } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: display.identity.builtin ? "laptopcomputer" : "display")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? Color.teal : Color.secondary)
                    .frame(width: 22).padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(display.name).fontWeight(.medium).lineLimit(2)
                    Text(display.settings.enabled
                         ? "\(display.settings.width) × \(display.settings.height)"
                         : "Disabled")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(display.identity.serialText.isEmpty
                         ? "No text serial"
                         : "Serial …\(display.identity.serialText.suffix(6))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.teal).font(.caption)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(selected ? Color.teal.opacity(0.11) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(selected ? Color.teal.opacity(0.22) : Color.clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(display.name), \(display.identity.serialText.isEmpty ? "Serial unavailable" : display.identity.serialText)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SystemSettingsCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Set up your displays").font(.system(size: 18, weight: .semibold))
                    Text("Arrange screens and adjust display settings in macOS.")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { model.openDisplaySettings() } label: {
                    Label("Open Displays Settings", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(model.busy)
                .help("Open macOS Displays settings and turn off auto-restore")
            }
            HStack {
                Text("Current layout").font(.subheadline.weight(.medium))
                Spacer()
                Label("Read-only", systemImage: "eye")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LayoutPreview(displays: model.displays, selectedID: model.selectedID)
                .frame(height: 150)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Current display layout preview")
                .accessibilityValue("\(model.displays.filter { $0.settings.enabled }.count) active displays")
            Text("Opening settings turns off auto-restore. Save your changes here, then turn it back on.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15).stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct RememberLayoutCard: View {
    @ObservedObject var model: AppModel
    @Binding var profileName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Remember your layout").font(.system(size: 18, weight: .semibold))
                    Text("Restore each display to its saved position when it reconnects.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "bookmark")
                    .font(.system(size: 21)).foregroundStyle(.teal).accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                TextField("Layout name", text: $profileName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name for the saved layout")
                Button("Save Current Layout") { model.save(name: profileName) }
                    .disabled(model.busy || profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if model.profiles.isEmpty {
                Text("Save a layout to enable restore and auto-restore.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Picker("Saved layout", selection: $model.selectedProfile) {
                        Text("Choose a layout").tag(nil as URL?)
                        ForEach(model.profiles, id: \.self) { url in
                            Text(url.deletingPathExtension().lastPathComponent).tag(Optional(url))
                        }
                    }
                    Button("Preview") { model.profileAction(execute: false) }
                        .disabled(model.selectedProfile == nil || model.busy)
                        .help("Preview the restore command without changing your displays")
                    Button { model.profileAction(execute: true) } label: {
                        Label("Restore Layout", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(model.selectedProfile == nil || model.busy)
                }
            }
            Divider()
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Restore after reconnect or wake", isOn: $model.autoRestore)
                        .toggleStyle(.switch)
                        .disabled(model.selectedProfile == nil)
                    Text("Keeps the selected layout in place while the app is running.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button { model.importProfile() } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(model.busy)
                .help("Import a saved JSON layout")
                Button { model.showProfiles() } label: {
                    Image(systemName: "folder")
                }
                .accessibilityLabel("Open the saved layouts folder")
                .help("Open the saved layouts folder")
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15).stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

struct DisplayDetails: View {
    let display: DisplaySnapshot
    let displays: [DisplaySnapshot]

    private var settings: DisplaySettings { display.settings }
    private var stateLabel: String {
        if !settings.enabled { return "Disabled" }
        if display.mirrorPrimaryID != nil { return "Mirroring" }
        if settings.x == 0 && settings.y == 0 { return "Main display" }
        return "Extended display"
    }
    private var summary: String {
        guard settings.enabled else { return "This display is currently disabled." }
        var values = ["\(settings.width) × \(settings.height)"]
        if let rate = settings.refreshRate { values.append("\(rate) Hz") }
        if settings.rotation != 0 { values.append("Rotated \(settings.rotation)°") }
        return values.joined(separator: " · ")
    }
    private var mirroring: String {
        if let sourceID = display.mirrorPrimaryID {
            guard let source = displays.first(where: { $0.id == sourceID }) else { return "Mirroring another display" }
            let serial = source.identity.serialText
            return "Mirroring \(source.name)\(serial.isEmpty ? "" : " · …\(serial.suffix(5))")"
        }
        let followers = displays.filter { $0.mirrorPrimaryID == display.id }.count
        return followers > 0 ? "Mirror source · \(followers) display\(followers == 1 ? "" : "s")" : "Not mirrored"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                Image(systemName: display.identity.builtin ? "laptopcomputer" : "display")
                    .font(.system(size: 22)).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(display.name).font(.headline)
                    Text(summary).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Text(stateLabel).font(.caption.weight(.medium))
                    .foregroundStyle(settings.enabled ? Color.teal : Color.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(settings.enabled ? Color.teal.opacity(0.09) : Color.secondary.opacity(0.09),
                                in: Capsule())
            }
            DisclosureGroup("Display details") {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                        detailRow("Serial", display.identity.serialText.isEmpty ? "Text serial unavailable" : display.identity.serialText)
                        detailRow("Position", "X \(settings.x) · Y \(settings.y)")
                        detailRow("Rotation", "\(settings.rotation)°")
                        detailRow("HiDPI · Color depth", "\(settings.scaled ? "On" : "Off") · \(settings.colorDepth) bit")
                        detailRow("Mirroring", mirroring)
                    }
                    DisclosureGroup("Supported modes (\(display.modes.count))") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 7) {
                                ForEach(display.modes, id: \.number) { mode in
                                    Text("\(mode.width) × \(mode.height) · \(mode.refreshRate.map { "\($0) Hz" } ?? "Refresh rate unavailable") · \(mode.colorDepth) bit\(mode.scaled ? " · HiDPI" : "")\(mode.current ? " · Current" : "")")
                                        .font(.caption)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                        }
                        .frame(maxHeight: 160)
                    }
                    ForEach(display.warnings, id: \.self) {
                        Label($0, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.top, 10)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct LayoutPreview: View {
    let displays: [DisplaySnapshot]
    let selectedID: UInt32?

    var body: some View {
        GeometryReader { geometry in
            let active = displays.filter { $0.settings.enabled && $0.mirrorPrimaryID == nil }
            let minX = active.map { $0.settings.x }.min() ?? 0
            let minY = active.map { $0.settings.y }.min() ?? 0
            let maxX = active.map { $0.settings.x + $0.settings.width }.max() ?? 1
            let maxY = active.map { $0.settings.y + $0.settings.height }.max() ?? 1
            let scale = min((geometry.size.width - 70) / Double(max(1, maxX - minX)),
                            (geometry.size.height - 35) / Double(max(1, maxY - minY)))
            let offsetX = (geometry.size.width - Double(maxX - minX) * scale) / 2
            let offsetY = (geometry.size.height - Double(maxY - minY) * scale) / 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.025))
                ForEach(active, id: \.id) { display in
                    let settings = display.settings
                    let selected = display.id == selectedID
                    let isMain = settings.x == 0 && settings.y == 0
                    VStack(spacing: 5) {
                        Text(display.name).font(.system(size: 11, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.75)
                        Text(display.identity.serialText.isEmpty ? "No serial" : "…\(display.identity.serialText.suffix(5))")
                            .font(.system(size: 9, design: .monospaced)).opacity(0.65)
                        if isMain {
                            Text("Main display").font(.system(size: 9, weight: .medium)).opacity(0.75)
                        }
                    }
                    .padding(.horizontal, 5)
                    .frame(width: max(34, Double(settings.width) * scale - 5),
                           height: max(34, Double(settings.height) * scale - 5))
                    .background(selected ? Color.teal.opacity(0.13) : Color.secondary.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(selected ? Color.teal.opacity(0.7) : Color.secondary.opacity(0.25),
                                    lineWidth: selected ? 1.5 : 1)
                    }
                    .offset(x: offsetX + Double(settings.x - minX) * scale,
                            y: offsetY + Double(settings.y - minY) * scale)
                }
                if active.isEmpty {
                    Text("Checking connected displays.")
                        .font(.subheadline).foregroundStyle(.secondary).padding(22)
                }
            }
        }
    }
}
