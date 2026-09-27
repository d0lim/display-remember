import Combine
import Foundation
import ServiceManagement

/// Login registration changes only in response to an explicit setEnabled call.
@MainActor
public final class LoginItemController: ObservableObject {
    public enum Status: Equatable, Sendable {
        case notRegistered
        case enabled
        case requiresApproval
        case unavailable
    }

    public enum IntegrationError: LocalizedError {
        case unavailable

        public var errorDescription: String? {
            "Login item integration is unavailable in this environment."
        }
    }

    @Published public private(set) var status: Status = .unavailable
    private let allowIntegration: Bool

    /// Disable integration for screenshots and tests to avoid all operating-system calls.
    public init(allowIntegration: Bool = true) {
        self.allowIntegration = allowIntegration
        if allowIntegration { refresh() }
    }

    public func refresh() {
        guard allowIntegration else {
            status = .unavailable
            return
        }
        status = Self.mappedStatus(SMAppService.mainApp.status)
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard allowIntegration else { throw IntegrationError.unavailable }
        refresh()
        guard status != .unavailable else { throw IntegrationError.unavailable }
        if enabled && (status == .enabled || status == .requiresApproval) { return }
        if !enabled && status == .notRegistered { return }
        defer { refresh() }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    public func openSystemSettings() {
        guard allowIntegration else { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    static func mappedStatus(_ status: SMAppService.Status) -> Status {
        switch status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // A service the system has never seen can report notFound before its first registration.
        // Keep the explicit registration action available and let register() report any failure.
        case .notFound: return .notRegistered
        @unknown default: return .unavailable
        }
    }
}
