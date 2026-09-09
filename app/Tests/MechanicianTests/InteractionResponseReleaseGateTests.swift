import XCTest
@testable import Mechanician

@MainActor
final class InteractionResponseReleaseGateTests: XCTestCase {
    func testPersistenceFailureCannotReachProviderDelivery() {
        var delivered = false
        var outcome: InteractionResponseReleaseOutcome?

        releaseInteractionResponseAfterPublication(
            publish: { $0(false) },
            isStillOwned: { true },
            deliver: { delivered = true; return true },
            completion: { outcome = $0 })

        XCTAssertFalse(delivered)
        XCTAssertEqual(outcome, .persistenceFailed)
    }

    func testDeliveryObservesPublishedBytesBeforeFirstProviderWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("response.json")
        let bytes = Data(#"{"status":"selected","allow":true}"#.utf8)
        var observedPublishedBytes: Data?
        var outcome: InteractionResponseReleaseOutcome?

        releaseInteractionResponseAfterPublication(
            publish: { completion in
                do {
                    try bytes.write(to: file, options: .atomic)
                } catch {
                    XCTFail("fixture publication failed: \(error)")
                    completion(false)
                    return
                }
                completion(true)
            },
            isStillOwned: { true },
            deliver: {
                observedPublishedBytes = try? Data(contentsOf: file)
                return true
            },
            completion: { outcome = $0 })

        XCTAssertEqual(observedPublishedBytes, bytes)
        XCTAssertEqual(outcome, .delivered)
    }

    func testStopDuringPublicationPreventsLateProviderWrite() {
        var publicationCompletion: ((Bool) -> Void)?
        var owned = true
        var delivered = false
        var outcome: InteractionResponseReleaseOutcome?
        releaseInteractionResponseAfterPublication(
            publish: { publicationCompletion = $0 },
            isStillOwned: { owned },
            deliver: { delivered = true; return true },
            completion: { outcome = $0 })

        owned = false
        publicationCompletion?(true)

        XCTAssertFalse(delivered)
        XCTAssertEqual(outcome, .ownershipLost)
    }
}
