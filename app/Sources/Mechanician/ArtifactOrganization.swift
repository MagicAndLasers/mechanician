import SwiftUI

/// How the artifact browsers order and group rows.
///
/// This mirrors `FileBrowserPanelView`'s Finder-style column behaviour — click a column to sort by
/// it, click again to reverse — but the ordering itself lives here as pure functions so both the
/// narrow inspector panel and the standalone Artifacts window sort identically and can be tested
/// without a view.
enum ArtifactSort: String, CaseIterable, Codable {
    case name
    case modified
    case created
    case type
    case size

    var title: String {
        switch self {
        case .name: return "Name"
        case .modified: return "Modified"
        case .created: return "Created"
        case .type: return "Kind"
        case .size: return "Size"
        }
    }

    /// Finder's convention: text sorts A→Z by default, dates and sizes largest/newest first.
    var defaultsAscending: Bool {
        switch self {
        case .name, .type: return true
        case .modified, .created, .size: return false
        }
    }
}

enum ArtifactGrouping: String, CaseIterable, Codable {
    case none
    case conversation
    case workspace
    case type
    case origin

    var title: String {
        switch self {
        case .none: return "None"
        case .conversation: return "Conversation"
        case .workspace: return "Workspace"
        case .type: return "Kind"
        case .origin: return "Origin"
        }
    }
}

enum ArtifactRowDensity: String, CaseIterable, Codable {
    case compact
    case detailed

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .detailed: return "Detailed"
        }
    }
}

struct ArtifactOrganization: Equatable, Codable {
    var sort: ArtifactSort = .modified
    var ascending: Bool = false
    var grouping: ArtifactGrouping = .none
    var density: ArtifactRowDensity = .detailed
    /// Favourites are a user-declared pin, not a sort key; they stay on top of whatever order is
    /// selected unless the user turns that off.
    var favoritesFirst: Bool = true

    /// Finder's column semantics: selecting the active column reverses it, a new column adopts that
    /// column's natural direction rather than inheriting the previous one's.
    mutating func select(_ sort: ArtifactSort) {
        if self.sort == sort {
            ascending.toggle()
        } else {
            self.sort = sort
            ascending = sort.defaultsAscending
        }
    }

    /// Tolerant decode: an added field must never quarantine a stored preference.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sort = try c.decodeIfPresent(ArtifactSort.self, forKey: .sort) ?? .modified
        ascending = try c.decodeIfPresent(Bool.self, forKey: .ascending) ?? false
        grouping = try c.decodeIfPresent(ArtifactGrouping.self, forKey: .grouping) ?? .none
        density = try c.decodeIfPresent(ArtifactRowDensity.self, forKey: .density) ?? .detailed
        favoritesFirst = try c.decodeIfPresent(Bool.self, forKey: .favoritesFirst) ?? true
    }

    init(
        sort: ArtifactSort = .modified,
        ascending: Bool = false,
        grouping: ArtifactGrouping = .none,
        density: ArtifactRowDensity = .detailed,
        favoritesFirst: Bool = true
    ) {
        self.sort = sort
        self.ascending = ascending
        self.grouping = grouping
        self.density = density
        self.favoritesFirst = favoritesFirst
    }
}

/// An artifact's source size in bytes. The source string is the artifact, so this is its real
/// on-disk weight rather than a proxy.
func artifactSize(_ artifact: Artifact) -> Int {
    artifact.source.utf8.count
}

func artifactSizeLabel(_ artifact: Artifact) -> String {
    let bytes = artifactSize(artifact)
    if bytes < 1_024 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB"]
    var value = Double(bytes) / 1_024
    var unit = 0
    while value >= 1_024, unit < units.count - 1 {
        value /= 1_024
        unit += 1
    }
    return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unit])
}

/// Order artifacts for display. Ties always fall back to title then identity so the list cannot
/// reshuffle between renders when two artifacts share a timestamp — which they routinely do, because
/// a batch import stamps them all in the same instant.
func sortedArtifacts(
    _ artifacts: [Artifact],
    by organization: ArtifactOrganization
) -> [Artifact] {
    artifacts.sorted { a, b in
        if organization.favoritesFirst, a.favorite != b.favorite { return a.favorite }
        let ordered = artifactPrecedes(a, b, sort: organization.sort)
        if let ordered { return organization.ascending ? ordered : !ordered }
        let byTitle = a.title.localizedStandardCompare(b.title)
        if byTitle != .orderedSame { return byTitle == .orderedAscending }
        return a.uuid.uuidString < b.uuid.uuidString
    }
}

/// `nil` means "equal on this key" so the caller can apply its stable tiebreak without the direction
/// flip turning a tie into an arbitrary flapping order.
private func artifactPrecedes(
    _ a: Artifact,
    _ b: Artifact,
    sort: ArtifactSort
) -> Bool? {
    switch sort {
    case .name:
        let result = a.title.localizedStandardCompare(b.title)
        return result == .orderedSame ? nil : result == .orderedAscending
    case .modified:
        return a.updatedAt == b.updatedAt ? nil : a.updatedAt < b.updatedAt
    case .created:
        return a.createdAt == b.createdAt ? nil : a.createdAt < b.createdAt
    case .type:
        let result = a.type.localizedStandardCompare(b.type)
        return result == .orderedSame ? nil : result == .orderedAscending
    case .size:
        let (left, right) = (artifactSize(a), artifactSize(b))
        return left == right ? nil : left < right
    }
}

struct ArtifactGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let artifacts: [Artifact]
}

/// Split artifacts into display groups, each internally ordered by `organization`.
///
/// `workspaceName` is injected rather than read from `ProjectStore` so the grouping stays a pure
/// function — the window and the inspector panel resolve workspace names differently, and neither
/// needs a store to be running for this to be testable.
func groupedArtifacts(
    _ artifacts: [Artifact],
    by organization: ArtifactOrganization,
    workspaceName: (Artifact) -> String = { _ in "Workspace" }
) -> [ArtifactGroup] {
    let ordered = sortedArtifacts(artifacts, by: organization)
    guard organization.grouping != .none else {
        return [ArtifactGroup(id: "all", title: "", artifacts: ordered)]
    }

    var order: [String] = []
    var buckets: [String: [Artifact]] = [:]
    for artifact in ordered {
        let title = artifactGroupTitle(artifact, organization.grouping, workspaceName)
        if buckets[title] == nil {
            buckets[title] = []
            order.append(title)
        }
        buckets[title]?.append(artifact)
    }
    // Group order follows the row order already chosen, so the first group holds the first row the
    // user would have seen ungrouped. Sorting group headers independently would contradict the
    // column they just clicked.
    return order.map { title in
        ArtifactGroup(id: title, title: title, artifacts: buckets[title] ?? [])
    }
}

private func artifactGroupTitle(
    _ artifact: Artifact,
    _ grouping: ArtifactGrouping,
    _ workspaceName: (Artifact) -> String
) -> String {
    switch grouping {
    case .none:
        return ""
    case .conversation:
        let title = artifact.conversationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "No conversation" : title
    case .workspace:
        let name = workspaceName(artifact).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "No workspace" : name
    case .type:
        return artifact.type.isEmpty ? "Unknown" : artifact.type.uppercased()
    case .origin:
        return artifact.origin.isEmpty ? "Unknown" : artifact.origin.capitalized
    }
}

/// Per-surface persistence for the browsers' organization. The inspector panel and the Artifacts
/// window keep separate preferences: they are different shapes doing different jobs, and a sort that
/// suits a wide two-pane window is rarely the one wanted in a narrow inspector column.
@MainActor
final class ArtifactOrganizationStore: ObservableObject {
    static let panel = ArtifactOrganizationStore(
        key: "artifacts.organization.panel",
        fallback: ArtifactOrganization(sort: .modified, ascending: false, density: .compact))
    static let window = ArtifactOrganizationStore(
        key: "artifacts.organization.window",
        fallback: ArtifactOrganization())

    @Published var organization: ArtifactOrganization {
        didSet {
            guard organization != oldValue else { return }
            persist()
        }
    }

    private let key: String
    private let defaults: UserDefaults

    init(key: String, fallback: ArtifactOrganization, defaults: UserDefaults = .standard) {
        self.key = key
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(ArtifactOrganization.self, from: data) {
            organization = stored
        } else {
            organization = fallback
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(organization) else { return }
        defaults.set(data, forKey: key)
    }
}
