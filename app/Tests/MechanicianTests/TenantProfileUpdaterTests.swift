import XCTest
@testable import Mechanician

/// The profile IS the app's configuration, now arriving over a network we do not trust. Every test
/// here asks one question: can anything on the far end of that connection break a working install?
@MainActor
final class TenantProfileUpdaterTests: XCTestCase {
    private final class FetchCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    private func profile(
        tenantId: String = "acme",
        feed: String? = "https://example.invalid/profile",
        mode: TenantProfile.Update.ProfileUpdateMode? = nil,
        revision: Int? = nil
    ) -> TenantProfile {
        TenantProfile(
            tenantId: tenantId,
            displayName: tenantId.capitalized,
            update: TenantProfile.Update(
                profileFeedURL: feed, profileUpdateMode: mode, revision: revision))
    }

    /// A feed that answers with a document that is not newer is an ANSWER, not a fault. This used to
    /// be reported as `.failed`, so the Providers window told the user "Could not check for a
    /// configuration update" after a check that had worked perfectly, styled as a problem. Nothing
    /// is installed either way; only the classification differs, and the copy hangs off it.
    func testAFeedThatIsNotNewerIsNotAFailure() async {
        for servedRevision in [6, 5] {
            var installed = false
            let updater = TenantProfileUpdater(
                fetch: { _ in Data("body".utf8) },
                install: { _ in installed = true; return self.profile() },
                loadCandidate: { _ in
                    // Same tenant, different content, not a newer revision.
                    self.profile(tenantId: "acme", feed: "https://example.invalid/moved",
                                 revision: servedRevision)
                },
                currentProfile: { self.profile(revision: 6) },
                installedSignedProfile: { self.profile(revision: 6) })

            let outcome = await updater.check()

            XCTAssertFalse(installed, "a document that is not newer must never be installed")
            XCTAssertEqual(outcome, .notNewer(installedRevision: 6, servedRevision: servedRevision))
        }
    }

    /// A machine with local overrides must still be able to report "up to date".
    ///
    /// `TenantProfile.current` is the signed document with this install's overrides applied, so it
    /// can never equal a freshly signed document once anything is overridden. Comparing against it
    /// meant `unchanged` never fired on such a machine, and every check reported that the
    /// organization had published changes without marking them as a new version. It had not: the
    /// difference was the user's own local edits. Seen on a real managed laptop at revision 8.
    func testLocalOverridesDoNotMakeEveryCheckLookLikeADrift() async {
        let signedDocument = profile(revision: 8)
        // What the effective profile looks like once the user overrides a route locally.
        var effective = signedDocument
        effective.displayName = "Acme (locally edited)"

        var installed = false
        let updater = TenantProfileUpdater(
            fetch: { _ in Data("body".utf8) },
            install: { _ in installed = true; return signedDocument },
            loadCandidate: { _ in signedDocument },
            currentProfile: { effective },
            installedSignedProfile: { signedDocument })

        let outcome = await updater.check()

        XCTAssertFalse(installed)
        XCTAssertEqual(outcome, .unchanged,
                       "the feed served exactly what is installed; local edits are not a drift")
    }

    /// The counterpart: a genuinely newer document still installs.
    func testANewerRevisionStillInstalls() async {
        var installed = false
        let updater = TenantProfileUpdater(
            fetch: { _ in Data("body".utf8) },
            install: { _ in installed = true; return self.profile(revision: 7) },
            loadCandidate: { _ in self.profile(revision: 7) },
            currentProfile: { self.profile(revision: 6) },
            installedSignedProfile: { self.profile(revision: 6) })

        let outcome = await updater.check()

        XCTAssertTrue(installed)
        XCTAssertEqual(outcome, .updated(tenantId: "acme"))
    }

    func testLegacyUnnumberedProfileAcceptsExactlyANumberedMigration() async {
        var installed = false
        let updater = TenantProfileUpdater(
            fetch: { _ in Data("body".utf8) },
            install: { _ in installed = true; return self.profile(revision: 1) },
            loadCandidate: { _ in self.profile(mode: .manual, revision: 1) },
            currentProfile: { self.profile(revision: nil) },
            installedSignedProfile: { self.profile(revision: nil) })

        let outcome = await updater.check()

        XCTAssertTrue(installed)
        XCTAssertEqual(outcome, .updated(tenantId: "acme"))
    }

    func testLegacyUnnumberedProfileRejectsAnUnnumberedContentChange() async {
        var installed = false
        let updater = TenantProfileUpdater(
            fetch: { _ in Data("body".utf8) },
            install: { _ in installed = true; return self.profile() },
            loadCandidate: {
                _ in self.profile(feed: "https://example.invalid/moved", revision: nil)
            },
            currentProfile: { self.profile(revision: nil) },
            installedSignedProfile: { self.profile(revision: nil) })

        let outcome = await updater.check()

        XCTAssertFalse(installed)
        XCTAssertEqual(outcome, .notNewer(installedRevision: nil, servedRevision: nil))
    }

    func testNoFeedMeansNoNetworkAndNoChange() async {
        let fetches = FetchCounter()
        let updater = TenantProfileUpdater(
            fetch: { _ in fetches.increment(); return Data() },
            install: { _ in XCTFail("must not install"); return self.profile() },
            currentProfile: { self.profile(feed: nil) })

        let outcome = await updater.check()

        XCTAssertEqual(outcome, .notConfigured)
        XCTAssertEqual(fetches.value, 0)
    }

    func testManualModeMakesLaunchCheckNetworkSilentButKeepsExplicitCheck() async {
        let installed = profile(mode: .manual, revision: 8)
        let fetches = FetchCounter()
        let updater = TenantProfileUpdater(
            fetch: { _ in fetches.increment(); return Data("body".utf8) },
            install: { _ in XCTFail("must not install"); return installed },
            loadCandidate: { _ in installed },
            currentProfile: { installed },
            installedSignedProfile: { installed })

        let automaticOutcome = await updater.checkAutomaticallyIfNeeded()

        XCTAssertNil(automaticOutcome)
        XCTAssertEqual(fetches.value, 0)
        XCTAssertNil(updater.lastOutcome)
        XCTAssertNil(updater.lastCheckedAt)

        let explicitOutcome = await updater.check()

        XCTAssertEqual(explicitOutcome, .unchanged)
        XCTAssertEqual(fetches.value, 1)
        XCTAssertNotNil(updater.lastCheckedAt)
    }

    func testProfileWithoutModeKeepsLegacyAutomaticLaunchCheck() async {
        let installed = profile(revision: 8)
        let fetches = FetchCounter()
        let updater = TenantProfileUpdater(
            fetch: { _ in fetches.increment(); return Data("body".utf8) },
            install: { _ in XCTFail("must not install"); return installed },
            loadCandidate: { _ in installed },
            currentProfile: { installed },
            installedSignedProfile: { installed })

        let outcome = await updater.checkAutomaticallyIfNeeded()

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(fetches.value, 1)
    }

    func testMDMManagedProfileBypassesTheNetworkAndLocalInstaller() async {
        var currentProfileRead = false
        var installed = false
        let updater = TenantProfileUpdater(
            fetch: { _ in XCTFail("must not fetch"); return Data() },
            install: { _ in installed = true; return self.profile() },
            currentProfile: {
                currentProfileRead = true
                return self.profile()
            },
            isMDMManaged: { true })

        let outcome = await updater.check()

        XCTAssertEqual(outcome, .notConfigured)
        XCTAssertEqual(updater.lastOutcome, .notConfigured)
        XCTAssertNil(updater.lastCheckedAt)
        XCTAssertFalse(updater.isChecking)
        XCTAssertFalse(currentProfileRead)
        XCTAssertFalse(installed)
    }

    /// Being off the VPN is an ordinary condition for these feeds, not a fault to recover from.
    func testUnreachableFeedLeavesTheInstalledProfileAlone() async {
        struct Offline: Error {}
        var installed = false
        let updater = TenantProfileUpdater(
            fetch: { _ in throw Offline() },
            install: { _ in installed = true; return self.profile() },
            currentProfile: { self.profile() })

        let outcome = await updater.check()

        XCTAssertFalse(installed)
        guard case .failed = outcome else {
            return XCTFail("expected a soft failure, got \(outcome)")
        }
    }

    func testUnsignedOrTamperedDocumentIsNeverInstalled() async {
        var installed = false
        let updater = TenantProfileUpdater(
            fetch: { _ in Data(#"{"profile":{"tenantId":"acme"}}"#.utf8) },
            install: { _ in installed = true; return self.profile() },
            currentProfile: { self.profile() })

        let outcome = await updater.check()

        XCTAssertFalse(installed, "an unverifiable document must not reach the installer")
        guard case .failed = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
    }

    /// Signature verification runs BEFORE the served tenantId is believed, so a feed cannot migrate
    /// this Mac onto somebody else's tenant.
    func testDocumentForAnotherTenantIsRejected() async {
        var installed = false
        let updater = TenantProfileUpdater(
            fetch: { _ in Data("unsigned body".utf8) },
            install: { _ in installed = true; return self.profile(tenantId: "other") },
            currentProfile: { self.profile(tenantId: "acme") })

        let outcome = await updater.check()

        XCTAssertFalse(installed)
        guard case .failed = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
    }

    func testOnlyHTTPSFeedsAreContacted() async {
        let fetches = FetchCounter()
        let updater = TenantProfileUpdater(
            fetch: { _ in fetches.increment(); return Data() },
            install: { _ in XCTFail("must not install"); return self.profile() },
            currentProfile: { self.profile(feed: "http://example.invalid/profile") })

        let outcome = await updater.check()

        XCTAssertEqual(outcome, .notConfigured)
        XCTAssertEqual(fetches.value, 0, "plain HTTP must not be fetched")
    }

    func testRevisionPolicyAllowsOneLegacyMigrationThenRequiresAnIncrease() {
        XCTAssertFalse(TenantProfileUpdater.revisionAdvances(current: nil, candidate: nil))
        XCTAssertFalse(TenantProfileUpdater.revisionAdvances(current: nil, candidate: 0))
        XCTAssertTrue(TenantProfileUpdater.revisionAdvances(current: nil, candidate: 1))
        XCTAssertTrue(TenantProfileUpdater.revisionAdvances(current: 1, candidate: 2))
        XCTAssertFalse(TenantProfileUpdater.revisionAdvances(current: 1, candidate: nil))
        XCTAssertFalse(TenantProfileUpdater.revisionAdvances(current: 1, candidate: 1))
        XCTAssertFalse(TenantProfileUpdater.revisionAdvances(current: 2, candidate: 1))
    }
}
