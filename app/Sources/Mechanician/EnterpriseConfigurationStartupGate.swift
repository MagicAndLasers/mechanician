import Foundation

/// One launch-static answer to whether enterprise configuration is safe to use.
///
/// A malformed forced preference resolves to no managed policy, which otherwise looks identical
/// to an unmanaged install at call sites using `ManagedEnterprisePolicy.current`. Keep the two
/// resolution errors explicit so every product entry point and unattended runtime fails closed.
enum EnterpriseConfigurationStartupGate {
    static var currentAllowsRuntime: Bool {
        allowsRuntime(
            managedPolicyStartupError: ManagedEnterprisePolicy.startupError,
            tenantProfileStartupError: TenantProfile.startupError)
    }

    static func allowsRuntime(
        managedPolicyStartupError: String?,
        tenantProfileStartupError: String?
    ) -> Bool {
        managedPolicyStartupError == nil && tenantProfileStartupError == nil
    }
}
