import XCTest
@testable import Mechanician

/// Reported straight from the tenant machine: "I still do not see the updated models after updating
/// the config", and the only way to answer it was reading a file out of Application Support with a
/// Python one-liner. That is not a question a user can be asked to answer.
///
/// The revision is the load-bearing fact. The app refuses a profile whose revision does not advance,
/// so a number that has not moved is the clearest evidence a publish did not land — and a number
/// that HAS moved while the active one has not means the answer is simply "restart".
final class ConfigurationRevisionVisibilityTests: XCTestCase {
    private func profile(named name: String, revision: Int?) -> TenantProfile {
        var p = TenantProfile(
            tenantId: name.lowercased(),
            displayName: name,
            routes: [
                TenantProfile.Route(
                    routeId: "\(name.lowercased())-vertex",
                    adapter: "claude-vertex",
                    vertex: .init(projectId: "p", region: "global"),
                    models: [TenantProfile.Model(id: "claude-opus-4-8", isDefault: true)]),
            ])
        p.update = TenantProfile.Update(
            profileFeedURL: "https://example.invalid/feed", revision: revision)
        return p
    }

    func testTheSummaryNamesTheConfigurationAndItsRevision() {
        let summary = TenantProfile.configurationSummary(for: profile(named: "Acme", revision: 10))
        XCTAssertEqual(summary, "Acme configuration · revision 10")
    }

    func testAProfileWithNoRevisionStillNamesItself() {
        // A hand-installed profile may declare no revision. Saying nothing at all would be worse
        // than saying which configuration is running.
        XCTAssertEqual(
            TenantProfile.configurationSummary(for: profile(named: "Acme", revision: nil)),
            "Acme configuration")
    }

    func testThePublicBuildSaysNothing() {
        // No managed configuration, nothing to explain. The public app must not grow a line about
        // configurations it does not have.
        let plain = TenantProfile(tenantId: "default", displayName: "Mechanician", routes: [])
        XCTAssertNil(TenantProfile.configurationSummary(for: plain))
    }

    // MARK: A current revision does not mean a current model list

    private func route(_ id: String, models: [String]) -> TenantProfile.Route {
        TenantProfile.Route(
            routeId: id,
            adapter: "claude-vertex",
            vertex: .init(projectId: "p", region: "global"),
            models: models.enumerated().map {
                TenantProfile.Model(id: $1, isDefault: $0 == 0)
            })
    }

    /// The tenant report this exists for. An administrator published a revision that REMOVED
    /// `claude-opus-5` and added `claude-opus-4-8[1m]`; the Mac installed it and reported the new
    /// revision; the picker still listed the old models. Both facts were true at once, because a
    /// local override replaces the published list wholesale and nothing said so.
    func testAnOverriddenListDisagreesWithACurrentRevision() {
        let signed = TenantProfile(
            tenantId: "acme", displayName: "Acme",
            routes: [route("acme-vertex", models: ["claude-opus-4-8", "claude-opus-4-8[1m]"])])
        var effective = signed
        effective.routes = [route("acme-vertex", models: ["claude-opus-5", "claude-opus-4-8"])]

        XCTAssertTrue(
            TenantProfile.modelsAreLocallyOverridden(effective: effective, signed: signed),
            "A local list that differs from the published one must be reported as overridden")
        // The symptom, stated as the app sees it: the withdrawn model is still on offer.
        XCTAssertEqual(
            effective.declaredModels(for: .claudeVertex).map(\.id),
            ["claude-opus-5", "claude-opus-4-8"])
    }

    func testAnUneditedInstallIsNotReportedAsOverridden() {
        // The ordinary case, and the one that must stay silent: warning every managed user that
        // their list was edited would make the real warning worthless.
        let signed = TenantProfile(
            tenantId: "acme", displayName: "Acme",
            routes: [route("acme-vertex", models: ["claude-opus-4-8", "claude-sonnet-5"])])
        XCTAssertFalse(
            TenantProfile.modelsAreLocallyOverridden(effective: signed, signed: signed))
    }

    func testAnOverrideEditedBackToThePublishedListIsNotReported() {
        // `ManagedConfigurationOverrides` stores a list, not a diff, so a user who edits and then
        // restores the published set still has an override on disk. What matters to the reader is
        // whether the list they are looking at differs, not whether a file exists.
        let signed = TenantProfile(
            tenantId: "acme", displayName: "Acme",
            routes: [route("acme-vertex", models: ["claude-opus-4-8", "claude-sonnet-5"])])
        var effective = signed
        effective.routes = [route("acme-vertex", models: ["claude-opus-4-8", "claude-sonnet-5"])]
        XCTAssertFalse(
            TenantProfile.modelsAreLocallyOverridden(effective: effective, signed: signed))
    }

    func testALocallyAuthoredRouteIsNotAnOverride() {
        // A route the user added themselves has no published list to contradict. Reporting it would
        // tell someone with no managed configuration that their configuration is out of date.
        let signed = TenantProfile(tenantId: "default", displayName: "Mechanician", routes: [])
        var effective = signed
        effective.routes = [route("local-vertex", models: ["claude-opus-4-8"])]
        XCTAssertFalse(
            TenantProfile.modelsAreLocallyOverridden(effective: effective, signed: signed))
    }

    /// Proves the override path itself produces the state above, rather than only asserting that a
    /// hand-built pair of profiles compares unequal.
    func testTheOverrideMechanismProducesTheDisagreement() {
        let signed = TenantProfile(
            tenantId: "acme", displayName: "Acme",
            routes: [route("acme-vertex", models: ["claude-opus-4-8", "claude-opus-4-8[1m]"])])
        var overrides = ManagedConfigurationOverrides()
        overrides.routes["acme-vertex"] = ManagedConfigurationOverrides.Route(
            models: [TenantProfile.Model(id: "claude-opus-5", isDefault: true)])

        let effective = overrides.applied(to: signed)
        XCTAssertEqual(effective.declaredModels(for: .claudeVertex).map(\.id), ["claude-opus-5"])
        XCTAssertTrue(
            TenantProfile.modelsAreLocallyOverridden(effective: effective, signed: signed))
    }
}
