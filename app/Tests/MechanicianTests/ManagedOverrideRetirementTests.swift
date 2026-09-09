import XCTest
@testable import Mechanician

/// Reported from a managed laptop: an administrator published a revision that withdrew a model and
/// added another, the Mac installed it and correctly reported the new revision, and the picker kept
/// offering the withdrawn model anyway. Both halves were true at once. A local override replaces the
/// published model list wholesale and nothing in the app had any notion that the list it was
/// replacing had since changed, so the published document could never win.
///
/// The rule these tests pin is a three-way merge: the revision being replaced is the base, the
/// override is ours, the incoming revision is theirs. A field the publisher left alone keeps its
/// local edit, because the reason for the edit still stands. A field the publisher changed is theirs
/// again, because they have since spoken about exactly the value being overridden.
@MainActor
final class ManagedOverrideRetirementTests: XCTestCase {
    private func route(
        _ id: String = "acme-vertex",
        name: String? = "Acme Vertex",
        project: String = "p",
        region: String = "global",
        models: [String]
    ) -> TenantProfile.Route {
        TenantProfile.Route(
            routeId: id,
            displayName: name,
            adapter: "claude-vertex",
            vertex: .init(projectId: project, region: region),
            models: models.enumerated().map { TenantProfile.Model(id: $1, isDefault: $0 == 0) },
            isDefault: true)
    }

    private func profile(_ routes: [TenantProfile.Route], revision: Int? = nil) -> TenantProfile {
        var p = TenantProfile(tenantId: "acme", displayName: "Acme", routes: routes)
        p.update = TenantProfile.Update(
            profileFeedURL: "https://example.invalid/feed", revision: revision)
        return p
    }

    private func modelOverride(_ ids: [String]) -> ManagedConfigurationOverrides {
        var overrides = ManagedConfigurationOverrides()
        overrides.routes["acme-vertex"] = ManagedConfigurationOverrides.Route(
            models: ids.enumerated().map { TenantProfile.Model(id: $1, isDefault: $0 == 0) })
        return overrides
    }

    // MARK: The reported case

    func testAPublishedModelChangeTakesBackALocalModelList() {
        let previous = profile([route(models: ["claude-opus-5", "claude-opus-4-8"])], revision: 8)
        let next = profile(
            [route(models: ["claude-opus-4-8", "claude-opus-4-8[1m]"])], revision: 10)

        let (reduced, retired) = modelOverride(["claude-opus-5"])
            .retiringSuperseded(previous: previous, next: next)

        XCTAssertNil(reduced.routes["acme-vertex"],
                     "an override with nothing left in it must not linger in the file")
        XCTAssertEqual(retired.map(\.sentence), ["Models on Acme Vertex"])
        // The point of the whole exercise: the published list governs again.
        XCTAssertEqual(
            reduced.applied(to: next).declaredModels(for: .claudeVertex).map(\.id),
            ["claude-opus-4-8", "claude-opus-4-8[1m]"])
    }

    /// Without this the fix would be indistinguishable from "publishing wipes local edits", which is
    /// the behaviour that was explicitly not chosen. The escape hatch exists because a deployment
    /// may not carry a model the profile names, and that reason survives an unrelated republish.
    func testAnUnrelatedRepublishLeavesTheLocalListAlone() {
        let models = ["claude-opus-5", "claude-opus-4-8"]
        let previous = profile([route(region: "global", models: models)], revision: 8)
        let next = profile([route(region: "us-east5", models: models)], revision: 10)

        let (reduced, retired) = modelOverride(["claude-opus-4-8"])
            .retiringSuperseded(previous: previous, next: next)

        XCTAssertEqual(reduced.routes["acme-vertex"]?.models?.map(\.id), ["claude-opus-4-8"])
        XCTAssertTrue(retired.isEmpty)
    }

    func testEachFieldIsJudgedOnItsOwn() {
        // The publisher moved the region and left the model list alone. Only the region override is
        // superseded; retiring the whole route override would discard an edit nobody contradicted.
        let previous = profile([route(region: "global", models: ["claude-opus-4-8"])], revision: 8)
        let next = profile([route(region: "us-east5", models: ["claude-opus-4-8"])], revision: 10)

        var overrides = modelOverride(["claude-haiku-4-5"])
        overrides.routes["acme-vertex"]?.vertexRegion = "europe-west1"

        let (reduced, retired) = overrides.retiringSuperseded(previous: previous, next: next)

        XCTAssertEqual(reduced.routes["acme-vertex"]?.models?.map(\.id), ["claude-haiku-4-5"])
        XCTAssertNil(reduced.routes["acme-vertex"]?.vertexRegion)
        XCTAssertEqual(retired.map(\.sentence), ["Region on Acme Vertex"])
    }

    func testAProjectChangeTakesBackAProjectOverride() {
        let previous = profile([route(project: "old-project", models: ["claude-opus-4-8"])],
                               revision: 8)
        let next = profile([route(project: "new-project", models: ["claude-opus-4-8"])],
                           revision: 10)

        var overrides = ManagedConfigurationOverrides()
        overrides.routes["acme-vertex"] = ManagedConfigurationOverrides.Route(
            vertexProjectId: "my-own-project")

        let (reduced, retired) = overrides.retiringSuperseded(previous: previous, next: next)

        XCTAssertNil(reduced.routes["acme-vertex"])
        XCTAssertEqual(retired.map(\.sentence), ["Project on Acme Vertex"])
    }

    func testAWithdrawnRouteTakesItsOverrideWithIt() {
        let previous = profile([route(models: ["claude-opus-4-8"])], revision: 8)
        let next = profile([route("other-vertex", name: "Other", models: ["claude-opus-4-8"])],
                           revision: 10)

        let (reduced, retired) = modelOverride(["claude-opus-5"])
            .retiringSuperseded(previous: previous, next: next)

        XCTAssertTrue(reduced.routes.isEmpty,
                      "an override keyed to a route that no longer exists is dead weight, and would "
                      + "reactivate if the id were ever republished")
        XCTAssertEqual(retired.map(\.sentence), ["Local edits on Acme Vertex"])
    }

    /// Without a base there is no evidence the publisher changed anything, so retiring would discard
    /// an edit nobody superseded.
    func testAnOverrideWithNoPublishedBaseIsLeftAlone() {
        let previous = profile([], revision: 8)
        let next = profile([route(models: ["claude-opus-4-8"])], revision: 10)

        let (reduced, retired) = modelOverride(["claude-opus-5"])
            .retiringSuperseded(previous: previous, next: next)

        XCTAssertEqual(reduced.routes["acme-vertex"]?.models?.map(\.id), ["claude-opus-5"])
        XCTAssertTrue(retired.isEmpty)
    }

    // MARK: Sources

    private func source(_ name: String, url: String) -> TenantProfile.ManagedSource {
        TenantProfile.ManagedSource(kind: "registry", name: name, url: url)
    }

    func testARepublishedSourceAddressTakesBackALocalAddress() {
        var previous = profile([]); previous.extensions.managedSources = [
            source("Registry", url: "https://old.example.com/servers.json")]
        var next = profile([], revision: 10); next.extensions.managedSources = [
            source("Registry", url: "https://new.example.com/servers.json")]

        var overrides = ManagedConfigurationOverrides()
        overrides.sources["Registry"] = ManagedConfigurationOverrides.Source(
            url: "https://mine.example.com/servers.json")

        let (reduced, retired) = overrides.retiringSuperseded(previous: previous, next: next)

        XCTAssertNil(reduced.sources["Registry"])
        XCTAssertEqual(retired.map(\.sentence), ["Address on Registry"])
    }

    /// `disabled` has no counterpart in a published document, so a new revision expresses no opinion
    /// about it. Turning a source someone switched off back on would be the app overruling a choice
    /// nobody contradicted — and for a VPN-only registry, a noisy one.
    func testTurningASourceOffSurvivesARepublish() {
        var previous = profile([]); previous.extensions.managedSources = [
            source("Registry", url: "https://old.example.com/servers.json")]
        var next = profile([], revision: 10); next.extensions.managedSources = [
            source("Registry", url: "https://new.example.com/servers.json")]

        var overrides = ManagedConfigurationOverrides()
        overrides.sources["Registry"] = ManagedConfigurationOverrides.Source(disabled: true)

        let (reduced, retired) = overrides.retiringSuperseded(previous: previous, next: next)

        XCTAssertEqual(reduced.sources["Registry"]?.disabled, true)
        XCTAssertTrue(retired.isEmpty)
    }

    // MARK: Through the updater

    func testInstallingANewerRevisionRetiresWhatItSupersedes() async {
        let previous = profile([route(models: ["claude-opus-5", "claude-opus-4-8"])], revision: 8)
        let next = profile([route(models: ["claude-opus-4-8", "claude-opus-4-8[1m]"])], revision: 10)

        var stored = modelOverride(["claude-opus-5"])
        var noted: [String] = []
        var notedRevision: Int?

        let updater = TenantProfileUpdater(
            fetch: { _ in Data("body".utf8) },
            install: { _ in next },
            loadCandidate: { _ in next },
            currentProfile: { previous },
            installedSignedProfile: { previous },
            loadOverrides: { stored },
            saveOverrides: { stored = $0 },
            recordRetirements: { retired, revision in
                noted = retired.map(\.sentence)
                notedRevision = revision
            })

        let outcome = await updater.check()

        XCTAssertEqual(outcome, .updated(tenantId: "acme", retired: ["Models on Acme Vertex"]))
        XCTAssertTrue(stored.routes.isEmpty, "the superseded override must be written back out")
        XCTAssertEqual(noted, ["Models on Acme Vertex"])
        XCTAssertEqual(notedRevision, 10, "the note has to name the revision that took the edit back")
    }

    /// The ordinary case has to stay silent, or the warning is worth nothing when it matters.
    func testAnUpdateThatSupersedesNothingSaysNothing() async {
        let models = ["claude-opus-4-8"]
        let previous = profile([route(region: "global", models: models)], revision: 8)
        let next = profile([route(region: "us-east5", models: models)], revision: 10)

        var saved = false
        let updater = TenantProfileUpdater(
            fetch: { _ in Data("body".utf8) },
            install: { _ in next },
            loadCandidate: { _ in next },
            currentProfile: { previous },
            installedSignedProfile: { previous },
            loadOverrides: { self.modelOverride(["claude-haiku-4-5"]) },
            saveOverrides: { _ in saved = true },
            recordRetirements: { _, _ in XCTFail("nothing was superseded") })

        let outcome = await updater.check()

        XCTAssertEqual(outcome, .updated(tenantId: "acme", retired: []))
        XCTAssertFalse(saved, "an untouched override file must not be rewritten")
    }

    /// A failed install must cost the user nothing. Retiring before the write would delete local
    /// edits in exchange for a revision that never landed.
    func testAFailedInstallLeavesLocalEditsAlone() async {
        struct Boom: Error {}
        let previous = profile([route(models: ["claude-opus-5"])], revision: 8)
        let next = profile([route(models: ["claude-opus-4-8"])], revision: 10)

        let updater = TenantProfileUpdater(
            fetch: { _ in Data("body".utf8) },
            install: { _ in throw Boom() },
            loadCandidate: { _ in next },
            currentProfile: { previous },
            installedSignedProfile: { previous },
            loadOverrides: { self.modelOverride(["claude-opus-5"]) },
            saveOverrides: { _ in XCTFail("must not rewrite overrides when the install failed") },
            recordRetirements: { _, _ in XCTFail("nothing was installed") })

        guard case .failed = await updater.check() else {
            return XCTFail("a throwing install must report a failure")
        }
    }

    // MARK: The note that outlives the launch

    func testTheNoteAccumulatesAcrossRevisionsUntilItIsRead() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        TenantProfileUpdater.recordRetirementNote(
            [.init(scope: "Acme Vertex", field: "Models")], revision: 9, defaults: defaults)
        TenantProfileUpdater.recordRetirementNote(
            [.init(scope: "Acme Vertex", field: "Region"),
             // Already recorded: two revisions can land before anyone opens Settings, and the same
             // sentence twice reads as two separate losses.
             .init(scope: "Acme Vertex", field: "Models")], revision: 10, defaults: defaults)

        let note = TenantProfileUpdater.pendingRetirementNote(defaults: defaults)
        XCTAssertEqual(note?.sentences,
                       ["Models on Acme Vertex", "Region on Acme Vertex"])
        XCTAssertEqual(note?.revision, 10)

        TenantProfileUpdater.clearRetirementNote(defaults: defaults)
        XCTAssertNil(TenantProfileUpdater.pendingRetirementNote(defaults: defaults))
    }
}
