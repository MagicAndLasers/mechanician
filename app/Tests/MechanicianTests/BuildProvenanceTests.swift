import XCTest
@testable import Mechanician

final class BuildProvenanceTests: XCTestCase {
    /// Bounded residency is now every channel's default. Eager residency holds every record
    /// resident, which on SQLite authority means decoding the whole corpus before the sidebar can
    /// paint, so it survives only as an explicit override. This replaces the earlier rule that
    /// forced public builds to eager and ignored overrides there.
    func testEveryChannelDefaultsToBoundedResidency() {
        for provenance in [BuildProvenance(
            dogfood: false, tenantId: nil, sourceCommit: "abc1234", sourceDiffSHA256: nil,
            helpCorpusSchemaVersion: nil, helpCorpusSHA256: nil),
                           BuildProvenance(
                            dogfood: true, tenantId: nil, sourceCommit: "abc1234",
                            sourceDiffSHA256: nil, helpCorpusSchemaVersion: nil,
                            helpCorpusSHA256: nil),
                           nil] {
            XCTAssertEqual(
                ConversationResidencyRolloutPolicy.mode(
                    provenance: provenance,
                    environmentValue: nil,
                    preferenceValue: nil),
                .boundedAfterRecovery)
            XCTAssertEqual(
                ConversationResidencyRolloutPolicy.mode(
                    provenance: provenance,
                    environmentValue: nil,
                    preferenceValue: "eager"),
                .eager,
                "the escape hatch back to the old behavior stays available on every channel")
            XCTAssertEqual(
                ConversationResidencyRolloutPolicy.mode(
                    provenance: provenance,
                    environmentValue: "eager",
                    preferenceValue: "boundedAfterRecovery"),
                .eager,
                "an explicit environment override still wins over a stored preference")
        }
    }

    func testDogfoodBuildHonorsResidencyKillSwitches() {
        let provenance = BuildProvenance(
            dogfood: true, tenantId: nil, sourceCommit: "abc1234", sourceDiffSHA256: nil,
            helpCorpusSchemaVersion: nil, helpCorpusSHA256: nil)
        XCTAssertEqual(
            ConversationResidencyRolloutPolicy.mode(
                provenance: provenance,
                environmentValue: "eager",
                preferenceValue: "boundedAfterRecovery"),
            .eager)
        XCTAssertEqual(
            ConversationResidencyRolloutPolicy.mode(
                provenance: provenance,
                environmentValue: "boundedAfterRecovery",
                preferenceValue: "eager"),
            .boundedAfterRecovery)
        XCTAssertEqual(
            ConversationResidencyRolloutPolicy.mode(
                provenance: provenance,
                environmentValue: nil,
                preferenceValue: "eager"),
            .eager)
        XCTAssertEqual(
            ConversationResidencyRolloutPolicy.mode(
                provenance: provenance,
                environmentValue: nil,
                preferenceValue: nil),
            .boundedAfterRecovery)
    }

    func testDogfoodBuildShowsShortSourceCommitWithoutChangingReleaseIdentity() throws {
        let provenance = try decode(#"{"dogfood":true,"sourceCommit":"E8C6D8E1234567890ABCDEF1234567890ABCDEF1"}"#)

        XCTAssertEqual(provenance.dogfoodSourceStamp, "Dogfood e8c6d8e")
        XCTAssertEqual(
            BuildVersionLabel.make(version: "0.23.0", build: "207", provenance: provenance),
            "0.23.0 (207) · Dogfood e8c6d8e"
        )
    }

    /// The case that actually cost us the time: build, edit, build again. Both apps carry the same
    /// commit and the same CFBundleVersion, so "on the new release" could not be verified by either
    /// of us and a fix that was not installed was trusted twice in one day. The diff hash was being
    /// recorded the whole time and nothing read it.
    func testABuildFromADirtyTreeSaysSoRatherThanClaimingItsCommit() throws {
        let clean = try decode("""
            {"dogfood":true,"sourceCommit":"e8c6d8e1234567890abcdef1234567890abcdef1",
             "sourceDiffSHA256":"\(BuildProvenance.cleanTreeDiffDigest)"}
            """)
        XCTAssertFalse(clean.builtFromModifiedTree)
        XCTAssertEqual(clean.dogfoodSourceStamp, "Dogfood e8c6d8e")

        let dirty = try decode("""
            {"dogfood":true,"sourceCommit":"e8c6d8e1234567890abcdef1234567890abcdef1",
             "sourceDiffSHA256":"9f2c1b0000000000000000000000000000000000000000000000000000000000"}
            """)
        XCTAssertTrue(dirty.builtFromModifiedTree)
        XCTAssertEqual(dirty.dogfoodSourceStamp, "Dogfood e8c6d8e + local changes")
        XCTAssertEqual(
            BuildVersionLabel.make(version: "0.26.30", build: "245", provenance: dirty),
            "0.26.30 (245) · Dogfood e8c6d8e + local changes")
    }

    /// An older bundle has no such key, and a build that cannot prove it was clean must not claim to
    /// be. Absent stays quiet rather than asserting either way; unrecognised counts as modified.
    func testAnAbsentDiffHashDoesNotClaimTheTreeWasClean() throws {
        let old = try decode(#"{"dogfood":true,"sourceCommit":"e8c6d8e1234567890abcdef1234567890abcdef1"}"#)
        XCTAssertFalse(old.builtFromModifiedTree)
        XCTAssertEqual(old.dogfoodSourceStamp, "Dogfood e8c6d8e")
    }

    func testPublicBuildKeepsNormalVersionLabel() throws {
        let provenance = try decode(#"{"dogfood":false,"sourceCommit":"e8c6d8e1234567890abcdef1234567890abcdef1"}"#)

        XCTAssertNil(provenance.dogfoodSourceStamp)
        XCTAssertEqual(
            BuildVersionLabel.make(version: "0.23.0", build: "207", provenance: provenance),
            "0.23.0 (207)"
        )
    }

    func testMalformedDogfoodCommitFailsClosedToNormalVersionLabel() throws {
        let provenance = try decode(#"{"dogfood":true,"sourceCommit":"working-tree"}"#)

        XCTAssertNil(provenance.dogfoodSourceStamp)
        XCTAssertEqual(
            BuildVersionLabel.make(version: "0.23.0", build: "207", provenance: provenance),
            "0.23.0 (207)"
        )
    }

    func testHelpAuthorityIdentityDecodesWithoutChangingOlderBundleCompatibility() throws {
        let current = try decode("""
            {"dogfood":false,"tenantId":"acme","sourceCommit":"\(String(repeating: "a", count: 40))",
             "sourceDiffSHA256":"\(String(repeating: "b", count: 64))",
             "helpCorpusSchemaVersion":1,
             "helpCorpusSHA256":"\(String(repeating: "c", count: 64))"}
            """)

        XCTAssertEqual(current.tenantId, "acme")
        XCTAssertEqual(current.helpCorpusSchemaVersion, 1)
        XCTAssertEqual(current.helpCorpusSHA256, String(repeating: "c", count: 64))

        let older = try decode(#"{"dogfood":false}"#)
        XCTAssertNil(older.tenantId)
        XCTAssertNil(older.helpCorpusSchemaVersion)
        XCTAssertNil(older.helpCorpusSHA256)
    }

    private func decode(_ json: String) throws -> BuildProvenance {
        try JSONDecoder().decode(BuildProvenance.self, from: Data(json.utf8))
    }
}
