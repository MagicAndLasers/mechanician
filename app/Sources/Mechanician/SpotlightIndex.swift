import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

// Makes Mechanician's conversations and artifacts first-class citizens of the OS: searchable from
// Spotlight, and (via the App Intents entities in MechanicianIntents) referenceable from Siri and
// Shortcuts. Both the Spotlight index and the entity queries can run in a background app process
// with no window open, so these read storage directly rather than through a live store.

/// Which library answers a headless Spotlight or App Intents read.
///
/// The legacy directories were the only source when every conversation was a file. Once the marker
/// names SQLite they stop being written: they hold the library exactly as it stood at the cutover.
/// Answering Siri from them means nothing created since can be picked and everything deleted since
/// still resolves, so when SQLite is the authority this reads the database or reports that it could
/// not — never the snapshot sitting beside it.
enum IndexedLibrarySource {
    case authority(LibraryAuthorityRepository)
    /// The legacy directories are not current and the authority could not be opened here. Distinct
    /// from an empty library: a caller that deletes an index before repopulating it must not treat
    /// "unknown" as "nothing".
    case authorityUnavailable
    case legacyDirectories(root: URL)

    /// The legacy directories may answer a read exactly when they may still be written. Reusing
    /// that one invariant keeps a reader from inventing a second, weaker rule: under SQLite they
    /// are a frozen snapshot, and a blocked launch has not established which library is real.
    ///
    /// The root comes from the recognition. The constant this replaced hardcoded `Mechanician`,
    /// which names the *public* app's directory on a Dev or tenant build — where the real root is
    /// `Mechanician-<slug>` — and the wrong directory entirely under a rollback generation.
    static func legacyDirectoryRoot(for recognition: StorageAuthorityRecognition) -> URL? {
        recognition.disposition.allowsLegacyWriters ? recognition.effectiveSupportRoot : nil
    }

    static var current: IndexedLibrarySource {
        if let root = legacyDirectoryRoot(for: StorageAuthorityBootstrap.current) {
            return .legacyDirectories(root: root)
        }
        guard let repository = LibraryAuthorityRepository.sharedIfActive else {
            return .authorityUnavailable
        }
        return .authority(repository)
    }
}

// MARK: - Lightweight, disk-backed views (no live store needed)

struct IndexedConversation: Identifiable {
    let id: UUID
    let title: String
    let cwd: String
    let snippet: String
    let updatedAt: Date
    var displayTitle: String { title.isEmpty ? "New conversation" : title }
    var cwdName: String { cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent }

    init(id: UUID, title: String, cwd: String, snippet: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.snippet = snippet
        self.updatedAt = updatedAt
    }

    /// The ready Conversation inventory already contains every fact Spotlight publishes. Reusing
    /// it avoids reparsing the entire legacy corpus beside the selected Conversation at launch.
    init(_ summary: ConversationSummary) {
        self.init(
            id: summary.id,
            title: summary.title,
            cwd: summary.workspaceCWD,
            snippet: summary.snippet,
            updatedAt: summary.updatedAt)
    }
}

struct IndexedArtifact: Identifiable {
    let id: UUID
    let title: String
    let type: String
    let cwd: String
    let conversationTitle: String
    var displayTitle: String { title.isEmpty ? "Artifact" : title }
    var cwdName: String { cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent }
}

enum ConversationIndex {
    /// Match the typed incremental-index path without decoding an entire large conversation.
    /// Optional Codable values are normally absent, but treat any non-null supersession marker as
    /// authoritative so a malformed empty provider handle cannot put withdrawn content back into
    /// Spotlight during the launch-time full reindex.
    private static func isSuperseded(_ message: [String: Any]) -> Bool {
        ["supersessionEventID", "supersededByEntryID", "supersededByFrameUUID"].contains { key in
            guard let value = message[key] else { return false }
            return !(value is NSNull)
        }
    }

    static func snippet(from messages: [[String: Any]]) -> String {
        let retained = messages.filter { !isSuperseded($0) }
        let firstUser = retained.first {
            ($0["kind"] as? String) == "user" && !(($0["text"] as? String) ?? "").isEmpty
        }
        return (firstUser?["text"] as? String)
            ?? (retained.first { !(($0["text"] as? String) ?? "").isEmpty }?["text"] as? String)
            ?? ""
    }

    /// Every conversation's display facts, from whichever library is authoritative. Nil means the
    /// answer is unknown, which a caller that deletes before it repopulates must not read as "none".
    static func allIfReadable() -> [IndexedConversation]? {
        switch IndexedLibrarySource.current {
        case .authority(let repository):
            // The summaries the sidebar itself is built from, so a picker and the app agree about
            // titles, ordering, and which conversations exist.
            return (try? repository.conversationSummaries())?.map(IndexedConversation.init)
        case .authorityUnavailable:
            return nil
        case .legacyDirectories(let root):
            return legacyDirectoryScan(root: root)
        }
    }

    static func all() -> [IndexedConversation] { allIfReadable() ?? [] }

    /// Read every conversation's metadata (+ a snippet) from disk. A lightweight JSON parse — it
    /// deliberately avoids decoding the full model so it's cheap to run for indexing/queries.
    /// Only correct while the legacy directory is still the library; see `IndexedLibrarySource`.
    private static func legacyDirectoryScan(root: URL) -> [IndexedConversation] {
        let directory = root.appendingPathComponent("conversations", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        let iso = ISO8601DateFormatter()
        var out: [IndexedConversation] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr) else { continue }
            let msgs = obj["messages"] as? [[String: Any]] ?? []
            let snippet = snippet(from: msgs)
            let updatedAt = (obj["updatedAt"] as? String).flatMap { iso.date(from: $0) } ?? .distantPast
            out.append(IndexedConversation(id: id, title: obj["title"] as? String ?? "",
                                           cwd: obj["cwd"] as? String ?? "",
                                           snippet: String(snippet.prefix(300)), updatedAt: updatedAt))
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }
}

enum ArtifactIndex {
    /// Every artifact's display facts, from whichever library is authoritative. Nil means the answer
    /// is unknown, which a caller that deletes before it repopulates must not read as "none".
    static func allIfReadable() -> [IndexedArtifact]? {
        switch IndexedLibrarySource.current {
        case .authority(let repository):
            return (try? repository.artifacts())?.map {
                IndexedArtifact(
                    id: $0.id,
                    title: $0.title,
                    type: $0.type,
                    cwd: $0.cwd,
                    conversationTitle: $0.conversationTitle)
            }
        case .authorityUnavailable:
            return nil
        case .legacyDirectories(let root):
            return legacyDirectoryScan(root: root)
        }
    }

    static func all() -> [IndexedArtifact] { allIfReadable() ?? [] }

    /// Read every artifact's metadata from disk (artifacts persist one JSON each, uuid under key "id").
    /// Only correct while the legacy directory is still the library; see `IndexedLibrarySource`.
    private static func legacyDirectoryScan(root: URL) -> [IndexedArtifact] {
        let directory = root.appendingPathComponent("artifacts", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        let iso = ISO8601DateFormatter()
        var out: [(IndexedArtifact, Date)] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let idStr = obj["id"] as? String, let id = UUID(uuidString: idStr) else { continue }
            let updatedAt = (obj["updatedAt"] as? String).flatMap { iso.date(from: $0) } ?? .distantPast
            out.append((IndexedArtifact(id: id, title: obj["title"] as? String ?? "",
                                        type: obj["type"] as? String ?? "",
                                        cwd: obj["cwd"] as? String ?? "",
                                        conversationTitle: obj["conversationTitle"] as? String ?? ""), updatedAt))
        }
        return out.sorted { $0.1 > $1.1 }.map { $0.0 }
    }
}

// MARK: - CoreSpotlight indexing

enum SpotlightIndex {
    static let conversationDomain = "conversations"
    static let artifactDomain = "artifacts"

    static func conversationUID(_ id: UUID) -> String { "conversation:\(id.uuidString)" }
    static func artifactUID(_ id: UUID) -> String { "artifact:\(id.uuidString)" }

    /// A tapped Spotlight result resolved back to a route. This used to be a private `Target` enum
    /// with the same two cases; it returns `MechanicianRoute` so Spotlight shares one router with
    /// the App Intents and notifications rather than carrying a parallel vocabulary.
    static func route(for uid: String) -> MechanicianRoute? {
        let parts = uid.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "conversation": return .conversation(id)
        case "artifact": return .artifact(id)
        default: return nil
        }
    }

    private static func item(uid: String, domain: String, title: String,
                             description: String, keywords: [String]) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: .text)
        attrs.title = title
        attrs.contentDescription = description
        attrs.keywords = keywords.filter { !$0.isEmpty }
        return CSSearchableItem(uniqueIdentifier: uid, domainIdentifier: domain, attributeSet: attrs)
    }

    private static func conversationItem(_ c: IndexedConversation) -> CSSearchableItem {
        let desc = [c.cwdName, c.snippet].filter { !$0.isEmpty }.joined(separator: " — ")
        let it = item(uid: conversationUID(c.id), domain: conversationDomain, title: c.displayTitle,
                      description: desc, keywords: ["Mechanician", "conversation", c.cwdName])
        // Golden Gate: link the searchable item to its App Intent entity (same identifier, so the
        // existing open-flow is unchanged) — Siri AI can then reason over it and act via the intents.
        if #available(macOS 15, *) { it.associateAppEntity(ConversationEntity(c)) }
        return it
    }

    private static func artifactItem(_ a: IndexedArtifact) -> CSSearchableItem {
        let desc = ["\(a.type) artifact", a.conversationTitle, a.cwdName].filter { !$0.isEmpty }.joined(separator: " — ")
        let it = item(uid: artifactUID(a.id), domain: artifactDomain, title: a.displayTitle,
                      description: desc, keywords: ["Mechanician", "artifact", a.type, a.cwdName])
        if #available(macOS 15, *) { it.associateAppEntity(ArtifactEntity(a)) }
        return it
    }

    // Incremental updates (called from the save/delete paths).
    static func indexConversation(id: UUID, title: String, cwd: String, snippet: String) {
        let c = IndexedConversation(id: id, title: title, cwd: cwd,
                                    snippet: String(snippet.prefix(300)), updatedAt: Date.distantPast)
        CSSearchableIndex.default().indexSearchableItems([conversationItem(c)])
    }
    static func deindexConversation(_ id: UUID) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [conversationUID(id)])
    }
    static func indexArtifact(id: UUID, title: String, type: String, cwd: String, conversationTitle: String) {
        let a = IndexedArtifact(id: id, title: title, type: type, cwd: cwd, conversationTitle: conversationTitle)
        CSSearchableIndex.default().indexSearchableItems([artifactItem(a)])
    }
    static func deindexArtifact(_ id: UUID) {
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [artifactUID(id)])
    }

    /// Full reindex after the authoritative launch inventory is ready. Conversation summaries are
    /// already bounded and complete, so the reindex never competes with launch by reading/parsing
    /// every large Conversation sidecar a second time. Artifacts are read on this background queue
    /// from whichever library owns them.
    ///
    /// A domain is deleted before it is repopulated, so an unreadable source must leave it alone
    /// rather than replace a correct index with an empty one until the next launch.
    static func reindexAll(conversationSummaries: [ConversationSummary]) {
        let conversationValues = conversationSummaries.map(IndexedConversation.init)
        DispatchQueue.global(qos: .utility).async {
            let convos = conversationValues.map(conversationItem)
            let arts = ArtifactIndex.allIfReadable()?.map(artifactItem)
            let index = CSSearchableIndex.default()
            index.deleteSearchableItems(withDomainIdentifiers: [conversationDomain]) { _ in
                index.indexSearchableItems(convos)
            }
            guard let arts else { return }
            index.deleteSearchableItems(withDomainIdentifiers: [artifactDomain]) { _ in
                index.indexSearchableItems(arts)
            }
        }
    }
}
