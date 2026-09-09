import XCTest
@testable import Mechanician

@MainActor
final class EnterpriseProfileImportTests: XCTestCase {
    private var profile: TenantProfile {
        TenantProfile(tenantId: "acme", displayName: "Acme")
    }

    func testVerifiedFileDeliveryRetainsBytesAndSourceNameUntilConsumed() throws {
        let expected = Data("signed-envelope".utf8)
        let coordinator = EnterpriseProfileImportCoordinator(
            read: { _ in expected },
            verify: { data in
                XCTAssertEqual(data, expected)
                return self.profile
            })

        coordinator.stage(URL(fileURLWithPath: "/tmp/Acme.mechanician-profile"))

        let delivery = try XCTUnwrap(coordinator.delivery)
        guard case .verified(let pending) = delivery.result else {
            return XCTFail("expected a verified import")
        }
        XCTAssertEqual(pending.data, expected)
        XCTAssertEqual(pending.profile, profile)
        XCTAssertEqual(pending.sourceName, "Acme.mechanician-profile")
        XCTAssertNotNil(coordinator.consume(delivery.id))
        XCTAssertNil(coordinator.delivery)
    }

    func testReadOrSignatureFailureBecomesAReviewableDelivery() throws {
        struct InvalidSignature: LocalizedError {
            var errorDescription: String? { "The signature is invalid." }
        }
        let coordinator = EnterpriseProfileImportCoordinator(
            read: { _ in Data() },
            verify: { _ in throw InvalidSignature() })

        coordinator.stage(URL(fileURLWithPath: "/tmp/Bad.mechanician-profile"))

        let delivery = try XCTUnwrap(coordinator.delivery)
        guard case .failed(let message) = delivery.result else {
            return XCTFail("expected a failed import")
        }
        XCTAssertEqual(message, "The signature is invalid.")
    }

    func testConsumingAnOldIdentityCannotClearANewerRequest() throws {
        let coordinator = EnterpriseProfileImportCoordinator(
            read: { Data($0.lastPathComponent.utf8) },
            verify: { _ in self.profile })
        coordinator.stage(URL(fileURLWithPath: "/tmp/First.mechanician-profile"))
        let firstID = try XCTUnwrap(coordinator.delivery?.id)
        coordinator.stage(URL(fileURLWithPath: "/tmp/Second.mechanician-profile"))
        let secondID = try XCTUnwrap(coordinator.delivery?.id)

        XCTAssertNil(coordinator.consume(firstID))
        XCTAssertEqual(coordinator.delivery?.id, secondID)
    }

    func testPublicBundleExportsAndOwnsEnterpriseProfileDocuments() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Mechanician-Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any])

        let exported = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(exported.first {
            $0["UTTypeIdentifier"] as? String == "ai.mechanician.enterprise-profile"
        })
        XCTAssertEqual(declaration["UTTypeConformsTo"] as? [String], ["public.json"])
        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertEqual(tags["public.filename-extension"] as? [String], ["mechanician-profile"])

        let documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let document = try XCTUnwrap(documents.first {
            ($0["LSItemContentTypes"] as? [String])?
                .contains("ai.mechanician.enterprise-profile") == true
        })
        XCTAssertEqual(document["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertEqual(document["LSHandlerRank"] as? String, "Owner")
    }
}
