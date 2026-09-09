import XCTest
@testable import Mechanician

@MainActor
final class ProviderCapabilityStoreTests: XCTestCase {
    private func key(
        access: ModelAccess = .codexSubscription,
        account: ProviderAccountInstanceID,
        epoch: Int = 0,
        model: String = "model-a",
        workspace: String = "workspace-a",
        policyRevision: UInt64 = 0
    ) -> ProviderCapabilityKey {
        ProviderCapabilityKey(
            access: access,
            accountInstanceID: account,
            credentialEpoch: epoch,
            modelID: model,
            workspace: ProviderCapabilityWorkspace(
                identity: workspace,
                policyRevision: policyRevision))
    }

    private func capability(
        _ id: String,
        availability: ProviderCapabilityAvailability = .available,
        support: MechanicianCapabilitySupport = .implemented
    ) -> ProviderCapability {
        ProviderCapability(
            id: id,
            providerAvailability: availability,
            mechanicianSupport: support,
            symmetry: .unclassified,
            operation: nil,
            constraints: [:],
            disclosures: [:],
            evidence: ProviderCapabilityEvidence(
                source: .providerResponse,
                operation: "fixture/read",
                revision: "1"))
    }

    func testAccountInstanceIdentityIsNonSecretDurableAndComplete() {
        let retained = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let generated = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let decoded = ProviderAccountStore.decodeAccountInstanceIDs([
            ModelAccess.claudeSubscription.rawValue: retained.uuidString,
            ModelAccess.openAIAPI.rawValue: "not-a-uuid",
            "credential": "must-not-be-retained",
        ], makeID: { ProviderAccountInstanceID(rawValue: generated) })

        XCTAssertEqual(decoded.count, ModelAccess.allCases.count)
        XCTAssertEqual(decoded[.claudeSubscription]?.rawValue, retained)
        XCTAssertEqual(decoded[.openAIAPI]?.rawValue, generated)

        let encoded = ProviderAccountStore.encodeAccountInstanceIDs(decoded)
        XCTAssertEqual(encoded.count, ModelAccess.allCases.count)
        XCTAssertEqual(encoded[ModelAccess.claudeSubscription.rawValue], retained.uuidString)
        XCTAssertNil(encoded["credential"])
    }

    func testFullKeySeparatesRoutesModelsWorkspacesAndPolicies() throws {
        let store = ProviderCapabilityStore()
        let codexAccount = ProviderAccountInstanceID()
        let claudeAccount = ProviderAccountInstanceID()
        XCTAssertTrue(store.setCurrentOwner(
            access: .codexSubscription, accountInstanceID: codexAccount, credentialEpoch: 2))
        XCTAssertTrue(store.setCurrentOwner(
            access: .claudeSubscription, accountInstanceID: claudeAccount, credentialEpoch: 7))

        let keys = [
            key(account: codexAccount, epoch: 2),
            key(account: codexAccount, epoch: 2, model: "model-b"),
            key(account: codexAccount, epoch: 2, workspace: "workspace-b"),
            key(account: codexAccount, epoch: 2, policyRevision: 1),
            key(access: .claudeSubscription, account: claudeAccount, epoch: 7),
        ]
        for (index, item) in keys.enumerated() {
            let ticket = try XCTUnwrap(store.beginRequest(for: item))
            XCTAssertTrue(store.publish(
                [capability("capability-\(index)")],
                ticket: ticket,
                adapterRevision: "fixture"))
        }

        XCTAssertEqual(store.snapshots.count, keys.count)
        for (index, item) in keys.enumerated() {
            XCTAssertEqual(store.snapshot(for: item).capabilities.map(\.id), ["capability-\(index)"])
        }
    }

    func testNewestTicketWinsAndFailureClearsStaleCapabilities() throws {
        let store = ProviderCapabilityStore()
        let account = ProviderAccountInstanceID()
        let item = key(account: account)
        XCTAssertTrue(store.setCurrentOwner(
            access: item.access, accountInstanceID: account, credentialEpoch: 0))

        let old = try XCTUnwrap(store.beginRequest(for: item))
        let newest = try XCTUnwrap(store.beginRequest(for: item))
        XCTAssertFalse(store.publish(
            [capability("stale")], ticket: old, adapterRevision: "old"))
        XCTAssertTrue(store.publish(
            [capability("current")], ticket: newest, adapterRevision: "new"))
        XCTAssertEqual(store.snapshot(for: item).capabilities.map(\.id), ["current"])

        let failing = try XCTUnwrap(store.beginRequest(for: item))
        XCTAssertTrue(store.fail(failing, message: "provider unavailable"))
        XCTAssertEqual(store.snapshot(for: item).phase, .failed("provider unavailable"))
        XCTAssertTrue(store.snapshot(for: item).capabilities.isEmpty)
    }

    func testEmptyAuthoritativeResponseAndAccountRotationClearAvailability() throws {
        let store = ProviderCapabilityStore()
        let firstAccount = ProviderAccountInstanceID()
        let firstKey = key(account: firstAccount)
        XCTAssertTrue(store.setCurrentOwner(
            access: firstKey.access, accountInstanceID: firstAccount, credentialEpoch: 0))
        let populated = try XCTUnwrap(store.beginRequest(for: firstKey))
        XCTAssertTrue(store.publish(
            [capability("review")], ticket: populated, adapterRevision: "one"))

        let empty = try XCTUnwrap(store.beginRequest(for: firstKey))
        XCTAssertTrue(store.publish([], ticket: empty, adapterRevision: "two"))
        XCTAssertEqual(store.snapshot(for: firstKey).phase, .ready)
        XCTAssertTrue(store.snapshot(for: firstKey).capabilities.isEmpty)

        let late = try XCTUnwrap(store.beginRequest(for: firstKey))
        let replacement = ProviderAccountInstanceID()
        XCTAssertTrue(store.setCurrentOwner(
            access: firstKey.access, accountInstanceID: replacement, credentialEpoch: 1))
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertFalse(store.publish(
            [capability("stale-account")], ticket: late, adapterRevision: "old"))
        XCTAssertFalse(store.setCurrentOwner(
            access: firstKey.access, accountInstanceID: replacement, credentialEpoch: 0))
    }

    func testUnknownCapabilitySurvivesButDoesNotBecomeImplemented() throws {
        let store = ProviderCapabilityStore()
        let account = ProviderAccountInstanceID()
        let item = key(account: account)
        XCTAssertTrue(store.setCurrentOwner(
            access: item.access, accountInstanceID: account, credentialEpoch: 0))
        let ticket = try XCTUnwrap(store.beginRequest(for: item))
        XCTAssertTrue(store.publish([
            capability(
                "provider.future-capability",
                availability: .experimental,
                support: .unimplemented),
        ], ticket: ticket, adapterRevision: "fixture"))

        let record = try XCTUnwrap(store.snapshot(for: item).capabilities.first)
        XCTAssertEqual(record.id, "provider.future-capability")
        XCTAssertEqual(record.providerAvailability, .experimental)
        XCTAssertEqual(record.mechanicianSupport, .unimplemented)
    }

    func testCanonicalClaudeModelUsesProviderCatalogAliasOnWire() {
        let alias = ModelCatalogEntry(
            selection: ModelSelection(
                access: .claudeSubscription,
                modelID: "sonnet"),
            displayName: "Sonnet",
            description: "",
            resolvedModelID: "claude-sonnet-5",
            isDefault: true,
            supportedEfforts: ["medium", "high"],
            capabilities: ["effort"])

        XCTAssertEqual(
            AgentBridge.providerCapabilityWireModelID(
                for: ModelSelection(
                    access: .claudeSubscription,
                    modelID: "claude-sonnet-5"),
                catalog: [alias]),
            "sonnet")
        XCTAssertEqual(
            AgentBridge.providerCapabilityWireModelID(
                for: ModelSelection(access: .claudeSubscription, modelID: ""),
                catalog: [alias]),
            "sonnet")
    }
}
