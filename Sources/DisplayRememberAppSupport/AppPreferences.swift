import Combine
import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case english = "en"
    case korean = "ko"

    public var id: String { rawValue }
}

/// App preferences contain only a profile filename, never an arbitrary file path.
@MainActor
public final class AppPreferences: ObservableObject {
    public static let pollingIntervals: [Double] = [2, 5, 10, 30, 60]

    enum Keys {
        static let language = "displayRemember.language"
        static let pollingInterval = "displayRemember.pollingInterval"
        static let autoRestore = "displayRemember.autoRestore"
        static let hideDockIcon = "displayRemember.hideDockIcon"
        static let selectedProfileName = "displayRemember.selectedProfileName"
    }

    @Published public var language: AppLanguage {
        didSet { defaults?.set(language.rawValue, forKey: Keys.language) }
    }

    @Published public var pollingInterval: Double {
        didSet {
            let normalized = Self.validInterval(pollingInterval)
            if pollingInterval != normalized { pollingInterval = normalized }
            defaults?.set(pollingInterval, forKey: Keys.pollingInterval)
        }
    }

    @Published public var autoRestore: Bool {
        didSet { defaults?.set(autoRestore, forKey: Keys.autoRestore) }
    }

    @Published public var hideDockIcon: Bool {
        didSet { defaults?.set(hideDockIcon, forKey: Keys.hideDockIcon) }
    }

    @Published public var selectedProfileName: String? {
        didSet {
            let normalized = Self.validProfileName(selectedProfileName)
            if selectedProfileName != normalized { selectedProfileName = normalized }
            persistProfileName()
        }
    }

    private let defaults: UserDefaults?

    /// Passing nil creates an independent in-memory instance for previews or tests.
    public init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        language = defaults?.string(forKey: Keys.language).flatMap(AppLanguage.init(rawValue:)) ?? .system
        if let number = defaults?.object(forKey: Keys.pollingInterval) as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID() {
            pollingInterval = Self.validInterval(number.doubleValue)
        } else {
            pollingInterval = 5
        }
        if let number = defaults?.object(forKey: Keys.autoRestore) as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            autoRestore = number.boolValue
        } else {
            autoRestore = false
        }
        if let number = defaults?.object(forKey: Keys.hideDockIcon) as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            hideDockIcon = number.boolValue
        } else {
            hideDockIcon = true
        }
        selectedProfileName = Self.validProfileName(defaults?.string(forKey: Keys.selectedProfileName))

        // Repair invalid persisted values as well as exposing safe values in memory.
        defaults?.set(language.rawValue, forKey: Keys.language)
        defaults?.set(pollingInterval, forKey: Keys.pollingInterval)
        defaults?.set(autoRestore, forKey: Keys.autoRestore)
        defaults?.set(hideDockIcon, forKey: Keys.hideDockIcon)
        persistProfileName()
    }

    private static func validInterval(_ value: Double) -> Double {
        pollingIntervals.contains(value) ? value : 5
    }

    private static func validProfileName(_ value: String?) -> String? {
        guard let value, value.hasSuffix(".json"),
              !value.contains("/"), !value.contains("\0") else {
            return nil
        }
        let stem = String(value.dropLast(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stem.isEmpty, stem != ".", stem != ".." else { return nil }
        return value
    }

    private func persistProfileName() {
        if let selectedProfileName {
            defaults?.set(selectedProfileName, forKey: Keys.selectedProfileName)
        } else {
            defaults?.removeObject(forKey: Keys.selectedProfileName)
        }
    }
}
