import XCTest
@testable import Mechanician

final class ArtifactOrganizationTests: XCTestCase {
    private func artifact(
        _ title: String,
        type: String = "html",
        source: String = "x",
        favorite: Bool = false,
        origin: String = "interactive",
        conversation: String = "",
        cwd: String = "",
        created: TimeInterval = 0,
        updated: TimeInterval = 0
    ) -> Artifact {
        Artifact(
            title: title,
            type: type,
            source: source,
            favorite: favorite,
            origin: origin,
            conversationTitle: conversation,
            cwd: cwd,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated))
    }

    func testSortsByEachColumnInBothDirections() {
        let items = [
            artifact("Beta", type: "svg", source: String(repeating: "a", count: 300), updated: 30),
            artifact("alpha", type: "csv", source: String(repeating: "a", count: 100), updated: 10),
            artifact("Gamma", type: "html", source: String(repeating: "a", count: 200), updated: 20),
        ]
        var organization = ArtifactOrganization(favoritesFirst: false)

        // Name uses localized standard comparison, so case does not split the alphabet.
        organization.sort = .name
        organization.ascending = true
        XCTAssertEqual(sortedArtifacts(items, by: organization).map(\.title), ["alpha", "Beta", "Gamma"])
        organization.ascending = false
        XCTAssertEqual(sortedArtifacts(items, by: organization).map(\.title), ["Gamma", "Beta", "alpha"])

        organization.sort = .modified
        organization.ascending = false
        XCTAssertEqual(sortedArtifacts(items, by: organization).map(\.title), ["Beta", "Gamma", "alpha"])

        organization.sort = .size
        organization.ascending = false
        XCTAssertEqual(sortedArtifacts(items, by: organization).map(\.title), ["Beta", "Gamma", "alpha"])

        organization.sort = .type
        organization.ascending = true
        XCTAssertEqual(sortedArtifacts(items, by: organization).map(\.title), ["alpha", "Gamma", "Beta"])
    }

    /// A batch import stamps every artifact in the same instant. Without a stable tiebreak the list
    /// reshuffles between renders, and rows move out from under the pointer.
    func testEqualKeysFallBackToAStableOrderInBothDirections() {
        let items = [
            artifact("Charlie", updated: 100),
            artifact("alpha", updated: 100),
            artifact("Bravo", updated: 100),
        ]
        var organization = ArtifactOrganization(sort: .modified, favoritesFirst: false)

        organization.ascending = false
        let descending = sortedArtifacts(items, by: organization).map(\.title)
        organization.ascending = true
        let ascending = sortedArtifacts(items, by: organization).map(\.title)

        XCTAssertEqual(descending, ["alpha", "Bravo", "Charlie"])
        XCTAssertEqual(ascending, descending, "a tie must not flip when the direction flips")
        XCTAssertEqual(sortedArtifacts(items, by: organization).map(\.title), ascending)
    }

    func testFavoritesStayOnTopOfWhicheverOrderIsSelectedUntilTurnedOff() {
        let items = [
            artifact("Newest", updated: 300),
            artifact("Pinned", favorite: true, updated: 100),
            artifact("Middle", updated: 200),
        ]
        var organization = ArtifactOrganization(sort: .modified, ascending: false)

        XCTAssertEqual(
            sortedArtifacts(items, by: organization).map(\.title),
            ["Pinned", "Newest", "Middle"])

        organization.favoritesFirst = false
        XCTAssertEqual(
            sortedArtifacts(items, by: organization).map(\.title),
            ["Newest", "Middle", "Pinned"])
    }

    func testColumnSelectionFollowsFinderSemantics() {
        var organization = ArtifactOrganization(sort: .modified, ascending: false)

        // Re-selecting the active column reverses it.
        organization.select(.modified)
        XCTAssertEqual(organization.sort, .modified)
        XCTAssertTrue(organization.ascending)

        // A new column adopts its own natural direction rather than inheriting the previous one's.
        organization.select(.name)
        XCTAssertEqual(organization.sort, .name)
        XCTAssertTrue(organization.ascending, "names start A→Z")

        organization.select(.size)
        XCTAssertEqual(organization.sort, .size)
        XCTAssertFalse(organization.ascending, "sizes start largest first")
    }

    func testGroupingKeepsRowOrderAndNamesEmptyBucketsHonestly() {
        let items = [
            artifact("One", conversation: "Design review", updated: 30),
            artifact("Two", conversation: "", updated: 20),
            artifact("Three", conversation: "Design review", updated: 10),
        ]
        let organization = ArtifactOrganization(
            sort: .modified, ascending: false, grouping: .conversation, favoritesFirst: false)

        let groups = groupedArtifacts(items, by: organization)

        XCTAssertEqual(groups.map(\.title), ["Design review", "No conversation"])
        XCTAssertEqual(groups[0].artifacts.map(\.title), ["One", "Three"])
        XCTAssertEqual(groups[1].artifacts.map(\.title), ["Two"])
        // Every artifact survives grouping exactly once.
        XCTAssertEqual(groups.flatMap(\.artifacts).count, items.count)
    }

    func testUngroupedProducesASingleUntitledGroup() {
        let items = [artifact("One"), artifact("Two")]
        let groups = groupedArtifacts(items, by: ArtifactOrganization(grouping: .none))

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].title, "")
        XCTAssertEqual(groups[0].artifacts.count, 2)
    }

    func testGroupsByWorkspaceThroughTheInjectedResolver() {
        let items = [
            artifact("One", cwd: "/a/mechanician", updated: 20),
            artifact("Two", cwd: "", updated: 10),
        ]
        let organization = ArtifactOrganization(grouping: .workspace, favoritesFirst: false)

        let groups = groupedArtifacts(items, by: organization) { artifact in
            artifact.cwd.isEmpty ? "" : (artifact.cwd as NSString).lastPathComponent
        }

        XCTAssertEqual(groups.map(\.title), ["mechanician", "No workspace"])
    }

    func testSizeLabelUsesBinaryUnits() {
        XCTAssertEqual(artifactSizeLabel(artifact("a", source: String(repeating: "x", count: 512))), "512 B")
        XCTAssertEqual(artifactSizeLabel(artifact("a", source: String(repeating: "x", count: 2_048))), "2.0 KB")
        // Multi-byte source counts real bytes, not characters.
        XCTAssertEqual(artifactSize(artifact("a", source: "é")), 2)
    }

    @MainActor
    func testOrganizationPersistsPerSurfaceAndToleratesAnUnknownStoredShape() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "artifact-organization-tests"))
        suite.removePersistentDomain(forName: "artifact-organization-tests")
        defer { suite.removePersistentDomain(forName: "artifact-organization-tests") }

        let store = ArtifactOrganizationStore(key: "panel", fallback: ArtifactOrganization(), defaults: suite)
        store.organization.select(.name)
        store.organization.grouping = .type
        // Density and favourites-first are presentation choices the user sets once and expects to
        // find again; both differ from their defaults here so a lost write cannot pass as correct.
        store.organization.density = .compact
        store.organization.favoritesFirst = false

        let reloaded = ArtifactOrganizationStore(
            key: "panel", fallback: ArtifactOrganization(), defaults: suite)
        XCTAssertEqual(reloaded.organization.sort, .name)
        XCTAssertEqual(reloaded.organization.grouping, .type)
        XCTAssertEqual(reloaded.organization.density, .compact)
        XCTAssertFalse(reloaded.organization.favoritesFirst)

        // A separate surface keeps its own preference rather than inheriting the other's.
        let other = ArtifactOrganizationStore(
            key: "window", fallback: ArtifactOrganization(), defaults: suite)
        XCTAssertEqual(other.organization.sort, .modified)
        XCTAssertEqual(other.organization.grouping, .none)

        // A stored blob missing newer fields must decode to defaults, not quarantine the preference.
        suite.set(Data(#"{"sort":"size"}"#.utf8), forKey: "legacy")
        let legacy = ArtifactOrganizationStore(
            key: "legacy", fallback: ArtifactOrganization(), defaults: suite)
        XCTAssertEqual(legacy.organization.sort, .size)
        XCTAssertEqual(legacy.organization.density, .detailed)
        XCTAssertTrue(legacy.organization.favoritesFirst)
    }
}
