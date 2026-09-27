import Foundation

/// Resolves strings from this package's resources, independent of Bundle.main.
public struct AppLocalizer {
    public let language: AppLanguage

    public init(language: AppLanguage) { self.language = language }

    public var locale: Locale {
        Locale(identifier: languageCode)
    }

    public func text(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments)
    }

    public func format(_ key: String, arguments: [CVarArg]) -> String {
        let localized = bundle?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
        guard !arguments.isEmpty else { return localized }
        return String(format: localized, locale: locale, arguments: arguments)
    }

    private var languageCode: String {
        switch language {
        case .english: return "en"
        case .korean: return "ko"
        case .system:
            return Bundle.preferredLocalizations(from: ["en", "ko"], forPreferences: Locale.preferredLanguages).first ?? "en"
        }
    }

    private var bundle: Bundle? {
        guard let resources = Self.resources,
              let path = resources.path(forResource: languageCode, ofType: "lproj"),
              let localized = Bundle(path: path) else { return Self.resources }
        return localized
    }

    // Resolve runtime locations only: SwiftPM's generated accessor embeds an
    // absolute build path and does not locate a resource bundle in app Resources.
    private static let resources: Bundle? = {
        let name = "display-remember_DisplayRememberAppSupport.bundle"
        let codeBundle = Bundle(for: ResourceBundleLocator.self)
        let anchors = [Bundle.main.resourceURL, Bundle.main.bundleURL,
                       Bundle.main.executableURL?.deletingLastPathComponent(),
                       codeBundle.resourceURL, codeBundle.bundleURL]
        for anchor in anchors.compactMap({ $0 }) {
            var directory = anchor
            for _ in 0..<4 {
                if let bundle = Bundle(url: directory.appendingPathComponent(name)) { return bundle }
                directory.deleteLastPathComponent()
            }
        }
        return nil
    }()
}

private final class ResourceBundleLocator: NSObject {}
