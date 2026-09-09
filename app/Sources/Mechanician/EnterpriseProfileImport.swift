import Foundation
import Combine
import UniformTypeIdentifiers

extension UTType {
    static let mechanicianEnterpriseProfile = UTType(
        exportedAs: "ai.mechanician.enterprise-profile",
        conformingTo: .json)
}

/// A signed enterprise-profile document that has already crossed the only trust boundary relevant
/// to the import review: its envelope signature was verified with the app's embedded public key.
struct PendingProfileImport: Identifiable {
    let id = UUID()
    let data: Data
    let profile: TenantProfile
    let sourceName: String
}

/// One file-open delivery for the Providers window. Launch Services may hand the app a document
/// before SwiftUI has mounted that window, so the verified bytes need a process-owned inbox rather
/// than an ephemeral notification.
struct EnterpriseProfileImportDelivery: Identifiable {
    enum Result {
        case verified(PendingProfileImport)
        case failed(String)
    }

    let id = UUID()
    let result: Result
}

/// Bridges Finder/browser document opens into the existing signed-profile review surface.
///
/// Files are read and verified at ingress. The Providers view later consumes the delivery and never
/// has to retain a security-scoped URL across launch restoration or a SwiftUI scene transition.
@MainActor
final class EnterpriseProfileImportCoordinator: ObservableObject {
    static let shared = EnterpriseProfileImportCoordinator()

    typealias Reader = (URL) throws -> Data
    typealias Verifier = (Data) throws -> TenantProfile

    @Published private(set) var delivery: EnterpriseProfileImportDelivery?

    private let read: Reader
    private let verify: Verifier

    init(
        read: @escaping Reader = { url in
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        },
        verify: @escaping Verifier = { data in
            try TenantProfile.loadSignedProfile(
                data, publicKey: TenantProfile.profileSigningPublicKey)
        }
    ) {
        self.read = read
        self.verify = verify
    }

    func stage(_ url: URL) {
        do {
            let data = try read(url)
            let profile = try verify(data)
            delivery = EnterpriseProfileImportDelivery(result: .verified(PendingProfileImport(
                data: data,
                profile: profile,
                sourceName: url.lastPathComponent)))
        } catch {
            delivery = EnterpriseProfileImportDelivery(result: .failed(error.localizedDescription))
        }
    }

    /// A delivery is acknowledged by identity so handling an older SwiftUI publisher emission can
    /// never clear a newer file-open request that arrived immediately behind it.
    func consume(_ id: UUID) -> EnterpriseProfileImportDelivery? {
        guard delivery?.id == id else { return nil }
        let consumed = delivery
        delivery = nil
        return consumed
    }
}
