import AppKit
import Foundation

/// The one process-wide answer to “may this caller construct or touch product stores?”
///
/// SwiftUI scenes, AppDelegate callbacks, App Intents, notification clicks and Services do not all
/// enter through the same lifecycle method. Every outside-product route must pass this gate before
/// mentioning a store singleton, especially while activation has fenced Legacy writers.
@MainActor
enum StorageProductAccessGate {
    static func allows(
        _ state: StorageAuthorityLaunchState,
        ownsProcessLease: Bool,
        enterpriseConfigurationAllowsRuntime: Bool =
            EnterpriseConfigurationStartupGate.currentAllowsRuntime
    ) -> Bool {
        guard enterpriseConfigurationAllowsRuntime,
              state.isConfigured,
              ownsProcessLease,
              state.decision == .product,
              case .sqlite(_, let database) = state.recognition.disposition,
              database.authorityState == .active else { return false }
        return true
    }

    @discardableResult
    static func perform(
        state: StorageAuthorityLaunchState,
        ownsProcessLease: Bool,
        blocked: @MainActor () -> Void,
        _ operation: () -> Void
    ) -> Bool {
        guard allows(state, ownsProcessLease: ownsProcessLease) else {
            blocked()
            return false
        }
        operation()
        return true
    }

    @discardableResult
    static func perform(_ operation: () -> Void) -> Bool {
        perform(
            state: .shared,
            ownsProcessLease: StorageAuthorityBootstrap.ownsProcessLease,
            blocked: focusBlockingWindow,
            operation)
    }

    @discardableResult
    static func request() -> Bool {
        guard allows(
            .shared,
            ownsProcessLease: StorageAuthorityBootstrap.ownsProcessLease
        ) else {
            focusBlockingWindow()
            return false
        }
        return true
    }

    private static func focusBlockingWindow() {
        (NSApp.delegate as? AppDelegate)?.focusStorageBlocker()
    }
}

enum StorageProductUnavailableError: LocalizedError {
    case libraryUnavailable

    var errorDescription: String? {
        String(localized:
            "Mechanician cannot safely open its library. Resolve Storage Recovery, then try again.")
    }
}
