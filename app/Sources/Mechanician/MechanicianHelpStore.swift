import CryptoKit
import Foundation
import SQLite3

/// Read-only access to the product knowledge sealed into this app build.
///
/// Product facts are vendor/build authority: sealed into the bundle at build time, signed, and
/// never written by the app, which is why this reader has no write path at all. The actor is the
/// common seam for the Help reader and the provider tool, so neither surface can develop a second
/// interpretation of the corpus.
actor MechanicianHelpStore {
    static let schemaVersion = 4
    static let applicationID: Int32 = 0x4D48_4C50 // MHLP

    private static let maximumQueryUTF8Bytes = 4 * 1_024
    private static let maximumTokenUTF8Bytes = 64
    private static let maximumQueryTokens = 12
    private static let maximumSearchResults = 24
    private static let maximumSearchResultUTF8Bytes = 128 * 1_024
    private static let maximumDemonstrationsPerArticle = 32
    private static let maximumDemoRecipeUTF8Bytes = 64 * 1_024
    private static let maximumDemoClaims = 16
    private static let maximumDemoTools = 12
    private static let maximumDemoSteps = 16
    private static let maximumDemoVerification = 8
    private static let maximumDemoFallback = 8
    private static let maximumGuides = 128
    private static let maximumGuidesPerArticle = 32
    private static let maximumGuideClaims = 16
    private static let maximumGuideSteps = 16
    private enum DemoToolEffect: Hashable, Sendable {
        case inventory
        case externalDynamic
        case inAppAdditive
    }

    private struct DemoToolPolicy: Sendable {
        let stepKind: MechanicianHelpDemoStepKind
        let effect: DemoToolEffect
    }

    /// Mirror the compiler's closed policy. A name is admitted only together with the step kind and
    /// recipe-level effect contract that keep an external action from masquerading as observation.
    private static let demoToolPolicies: [String: DemoToolPolicy] = [
        "CreateOrUpdateArtifact": DemoToolPolicy(stepKind: .act, effect: .inAppAdditive),
        "DiscoverAppActions": DemoToolPolicy(stepKind: .observe, effect: .inventory),
        "ListCapabilities": DemoToolPolicy(stepKind: .observe, effect: .inventory),
        "ListShortcuts": DemoToolPolicy(stepKind: .observe, effect: .inventory),
        "RunCapability": DemoToolPolicy(stepKind: .act, effect: .externalDynamic),
    ]

    private static let guideRevealTargets: [
        MechanicianHelpGuideRevealAction: Set<MechanicianHelpGuideTarget>
    ] = [
        .showHelpInspector: [.helpInspectorTab],
        .showHelpTopics: [.helpTopics, .helpSearchField],
        .showGuideArticle: [.helpArticleContent],
        .showGuideEvidence: [.helpArticleEvidence],
        .showGuideDemonstrations: [.helpDemonstrations],
        .showFilesInspector: [.conversationFilesTab],
        .showChangesInspector: [.conversationChangesTab],
        .showArtifactsInspector: [.conversationArtifactsTab],
        .showAgentsInspector: [.conversationAgentsTab],
        .showSkillsInspector: [.conversationSkillsTab],
        .showConversationControls: [
            .conversationModelControl, .conversationEffortControl,
            .conversationPermissionControl, .conversationComposer,
        ],
    ]

    private static let guideSurfaceTargets: [
        MechanicianHelpGuideSurface: Set<MechanicianHelpGuideTarget>
    ] = [
        .helpWorkspaceInspector: [
            .helpInspectorTab, .helpTopics, .helpSearchField, .helpArticleContent,
            .helpArticleEvidence, .helpDemonstrations,
        ],
        .conversationWorkspace: [
            .conversationFilesTab, .conversationChangesTab, .conversationArtifactsTab,
            .conversationAgentsTab, .conversationSkillsTab, .conversationModelControl,
            .conversationEffortControl, .conversationPermissionControl, .conversationComposer,
        ],
    ]

    private static let guideSurfaceRevealActions: [
        MechanicianHelpGuideSurface: Set<MechanicianHelpGuideRevealAction>
    ] = [
        .helpWorkspaceInspector: [
            .none, .showHelpInspector, .showHelpTopics, .showGuideArticle,
            .showGuideEvidence, .showGuideDemonstrations,
        ],
        .conversationWorkspace: [
            .none, .showFilesInspector, .showChangesInspector, .showArtifactsInspector,
            .showAgentsInspector, .showSkillsInspector, .showConversationControls,
        ],
    ]

    private struct SchemaObject: Equatable {
        let type: String
        let columnCount: Int
        let withoutRowID: Bool
        let strict: Bool
    }

    private struct SchemaColumn: Equatable {
        let name: String
        let type: String
        let notNull: Bool
        let primaryKeyPosition: Int
        let hidden: Int
    }

    nonisolated let metadata: MechanicianHelpMetadata
    private let database: OpaquePointer
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func databaseURL(resourceURL: URL?) throws -> URL {
        guard let resourceURL else { throw MechanicianHelpError.unavailable }
        let url = resourceURL.appendingPathComponent("MechanicianHelp.sqlite", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MechanicianHelpError.unavailable
        }
        return url
    }

    static func openBundled(
        resourceURL: URL? = Bundle.main.resourceURL,
        expectedBuild: MechanicianHelpBuildIdentity? = MechanicianHelpBuildIdentity.current()
    ) throws -> MechanicianHelpStore {
        try MechanicianHelpStore(
            databaseURL: databaseURL(resourceURL: resourceURL),
            expectedBuild: expectedBuild)
    }

    init(databaseURL: URL, expectedBuild: MechanicianHelpBuildIdentity? = nil) throws {
        var handle: OpaquePointer?
        let separator = databaseURL.absoluteString.contains("?") ? "&" : "?"
        let readOnlyURI = databaseURL.absoluteString + separator + "mode=ro&immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        guard sqlite3_open_v2(readOnlyURI, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw MechanicianHelpError.cannotOpen
        }

        do {
            guard sqlite3_db_readonly(handle, "main") == 1 else {
                throw MechanicianHelpError.cannotOpen
            }
            guard sqlite3_exec(handle, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK else {
                throw MechanicianHelpError.cannotOpen
            }
            try Self.validatePackagedArtifact(
                databaseURL: databaseURL,
                expectedBuild: expectedBuild)
            guard Self.integerPragma(handle, "application_id") == Self.applicationID else {
                throw MechanicianHelpError.wrongApplicationID
            }
            let foundSchema = Int(Self.integerPragma(handle, "user_version"))
            guard foundSchema == Self.schemaVersion else {
                throw MechanicianHelpError.unsupportedSchema(
                    found: foundSchema,
                    expected: Self.schemaVersion)
            }
            guard Self.textPragma(handle, "quick_check") == "ok" else {
                throw MechanicianHelpError.malformed("quick_check")
            }
            guard try Self.foreignKeyCheckIsEmpty(handle) else {
                throw MechanicianHelpError.malformed("foreign_key_check")
            }
            try Self.validateSchema(handle)
            let metadata = try Self.readMetadata(handle)
            try Self.validate(metadata: metadata, expectedBuild: expectedBuild)
            try Self.validateVocabulary(handle)
            try Self.validateCurrentClaimEvidence(handle)
            try Self.validateCurrentDemonstrationGrounding(handle)
            try Self.validateGuideAuthority(handle)
            try Self.validateFTSParity(handle)
            try Self.validateFTSSmokeQuery(handle)
            self.database = handle
            self.metadata = metadata
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(database)
    }

    func listSections() throws -> [MechanicianHelpSection] {
        let statement = try prepare("""
            SELECT s.id, s.title, s.ordinal,
                   a.id, a.title, a.icon, a.blurb, a.kind, a.lifecycle, a.ordinal
            FROM help_section s
            LEFT JOIN help_article a
              ON a.section_id = s.id AND a.lifecycle = 'current'
            ORDER BY s.ordinal, s.id, a.ordinal, a.id
            """)
        defer { sqlite3_finalize(statement) }

        struct SectionBuilder {
            let id: String
            let title: String
            let ordinal: Int
            var articles: [MechanicianHelpArticleSummary]
        }
        var builders: [SectionBuilder] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let sectionID = try text(statement, 0, "section id")
                let sectionTitle = try text(statement, 1, "section title")
                let sectionOrdinal = Int(sqlite3_column_int64(statement, 2))
                if builders.last?.id != sectionID {
                    builders.append(SectionBuilder(
                        id: sectionID,
                        title: sectionTitle,
                        ordinal: sectionOrdinal,
                        articles: []))
                } else if builders.last?.title != sectionTitle
                            || builders.last?.ordinal != sectionOrdinal {
                    throw MechanicianHelpError.malformed("inconsistent section row")
                }
                if sqlite3_column_type(statement, 3) != SQLITE_NULL {
                    builders[builders.count - 1].articles.append(try articleSummary(
                        statement,
                        offset: 3,
                        sectionID: sectionID))
                }
            case SQLITE_DONE:
                return builders.map {
                    MechanicianHelpSection(
                        id: $0.id,
                        title: $0.title,
                        ordinal: $0.ordinal,
                        articles: $0.articles)
                }
            default:
                throw queryError("list sections")
            }
        }
    }

    func article(id: String, includeHistory: Bool = false) throws -> MechanicianHelpArticle? {
        let statement = try prepare("""
            SELECT id, title, icon, blurb, kind, lifecycle, ordinal, section_id,
                   markdown, body_sha256
            FROM help_article
            WHERE id = ?1
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return nil
        case SQLITE_ROW:
            let lifecycle = try lifecycle(statement, 5, "article lifecycle")
            guard includeHistory || lifecycle == .current else { return nil }
            let markdown = try text(statement, 8, "article markdown")
            let digest = try text(statement, 9, "article digest")
            guard Self.sha256(markdown) == digest else {
                throw MechanicianHelpError.malformed("article digest")
            }
            let summary = MechanicianHelpArticleSummary(
                id: try text(statement, 0, "article id"),
                sectionID: try text(statement, 7, "article section"),
                title: try text(statement, 1, "article title"),
                icon: try text(statement, 2, "article icon"),
                blurb: try text(statement, 3, "article blurb"),
                kind: try claimKind(statement, 4, "article kind"),
                lifecycle: lifecycle,
                ordinal: Int(sqlite3_column_int64(statement, 6)))
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw MechanicianHelpError.malformed("duplicate article")
            }
            return MechanicianHelpArticle(
                summary: summary,
                markdown: markdown,
                evidence: try evidence(articleID: summary.id),
                demonstrations: try demonstrations(
                    articleID: summary.id,
                    includeHistory: includeHistory),
                guides: try guides(
                    articleID: summary.id,
                    includeHistory: includeHistory))
        default:
            throw queryError("read article")
        }
    }

    /// Returns reviewed demonstration plans attached to one article. These are advisory plans;
    /// callers must still match `requirements.tools` against the exact live route and invoke tools
    /// through the route's normal authorization path.
    func demonstrations(
        articleID: String,
        includeHistory: Bool = false
    ) throws -> [MechanicianHelpDemonstration] {
        let statement = try prepare("""
            SELECT d.id, d.article_id, d.title, d.outcome, d.lifecycle, d.ordinal,
                   d.recipe_json, d.recipe_sha256
            FROM help_demo d
            JOIN help_article a ON a.id = d.article_id
            WHERE d.article_id = ?1
              AND (?2 = 1 OR (d.lifecycle = 'current' AND a.lifecycle = 'current'))
            ORDER BY d.ordinal, d.id
            LIMIT ?3
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, articleID)
        sqlite3_bind_int(statement, 2, includeHistory ? 1 : 0)
        sqlite3_bind_int(statement, 3, Int32(Self.maximumDemonstrationsPerArticle + 1))
        var rows: [MechanicianHelpDemonstration] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard rows.count < Self.maximumDemonstrationsPerArticle else {
                    throw MechanicianHelpError.malformed("too many article demonstrations")
                }
                rows.append(try demonstration(statement))
            case SQLITE_DONE:
                return rows
            default:
                throw queryError("read demonstrations")
            }
        }
    }

    /// Returns the signed native walkthroughs in stable corpus order. Guides can reveal only
    /// app-owned semantic targets; they are not provider workflows and grant no tool authority.
    func guides(includeHistory: Bool = false) throws -> [MechanicianHelpGuide] {
        try readGuides(articleID: nil, includeHistory: includeHistory)
    }

    func guides(
        articleID: String,
        includeHistory: Bool = false
    ) throws -> [MechanicianHelpGuide] {
        guard Self.isHelpID(articleID) else {
            throw MechanicianHelpError.malformed("guide article id")
        }
        return try readGuides(articleID: articleID, includeHistory: includeHistory)
    }

    func guide(
        id: String,
        includeHistory: Bool = false
    ) throws -> MechanicianHelpGuide? {
        guard Self.isHelpID(id) else {
            throw MechanicianHelpError.malformed("guide id")
        }
        let statement = try prepare("""
            SELECT g.id, g.article_id, g.title, g.summary, g.surface, g.lifecycle, g.ordinal
            FROM help_guide g
            JOIN help_article a ON a.id = g.article_id
            WHERE g.id = ?1
              AND (?2 = 1 OR (g.lifecycle = 'current' AND a.lifecycle = 'current'))
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        sqlite3_bind_int(statement, 2, includeHistory ? 1 : 0)
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return nil
        case SQLITE_ROW:
            let result = try readGuide(statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw MechanicianHelpError.malformed("duplicate guide")
            }
            return result
        default:
            throw queryError("read guide")
        }
    }

    private func readGuides(
        articleID: String?,
        includeHistory: Bool
    ) throws -> [MechanicianHelpGuide] {
        let articleFilter = articleID == nil ? "" : "AND g.article_id = ?2"
        let historyIndex: Int32 = 1
        let limitIndex: Int32 = articleID == nil ? 2 : 3
        let limit = articleID == nil
            ? Self.maximumGuides
            : Self.maximumGuidesPerArticle
        let statement = try prepare("""
            SELECT g.id, g.article_id, g.title, g.summary, g.surface, g.lifecycle, g.ordinal
            FROM help_guide g
            JOIN help_article a ON a.id = g.article_id
            JOIN help_section s ON s.id = a.section_id
            WHERE (?1 = 1 OR (g.lifecycle = 'current' AND a.lifecycle = 'current'))
              \(articleFilter)
            ORDER BY s.ordinal, a.ordinal, a.id, g.ordinal, g.id
            LIMIT ?\(limitIndex)
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, historyIndex, includeHistory ? 1 : 0)
        if let articleID { bind(statement, 2, articleID) }
        sqlite3_bind_int(statement, limitIndex, Int32(limit + 1))
        var rows: [MechanicianHelpGuide] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard rows.count < limit else {
                    throw MechanicianHelpError.malformed("too many guides")
                }
                rows.append(try readGuide(statement))
            case SQLITE_DONE:
                return rows
            default:
                throw queryError("read guides")
            }
        }
    }

    private func readGuide(_ statement: OpaquePointer) throws -> MechanicianHelpGuide {
        let id = try text(statement, 0, "guide id")
        let articleID = try text(statement, 1, "guide article")
        let title = try text(statement, 2, "guide title")
        let summary = try text(statement, 3, "guide summary")
        guard let surface = MechanicianHelpGuideSurface(
            rawValue: try text(statement, 4, "guide surface")) else {
            throw MechanicianHelpError.malformed("guide surface")
        }
        let lifecycle = try lifecycle(statement, 5, "guide lifecycle")
        let ordinal = Int(sqlite3_column_int64(statement, 6))
        guard Self.isHelpID(id),
              Self.isHelpID(articleID),
              id.hasPrefix("\(articleID)."),
              Self.isGuideCopy(title, maximumUTF16Units: 160, maximumUTF8Bytes: 640),
              Self.isGuideCopy(summary, maximumUTF16Units: 600, maximumUTF8Bytes: 2_400),
              ordinal >= 0 else {
            throw MechanicianHelpError.malformed("guide identity")
        }
        return MechanicianHelpGuide(
            id: id,
            articleID: articleID,
            title: title,
            summary: summary,
            surface: surface,
            lifecycle: lifecycle,
            ordinal: ordinal,
            claimKeys: try guideClaimKeys(id: id, lifecycle: lifecycle),
            steps: try guideSteps(id: id, surface: surface),
            evidence: try evidence(guideID: id))
    }

    private func guideClaimKeys(
        id: String,
        lifecycle: MechanicianHelpLifecycle
    ) throws -> [String] {
        let statement = try prepare("""
            SELECT gc.claim_key, c.lifecycle
            FROM help_guide_claim gc
            JOIN help_claim c ON c.key = gc.claim_key
            WHERE gc.guide_id = ?1
            ORDER BY gc.ordinal, gc.claim_key
            LIMIT ?2
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        sqlite3_bind_int(statement, 2, Int32(Self.maximumGuideClaims + 1))
        var keys: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard keys.count < Self.maximumGuideClaims else {
                    throw MechanicianHelpError.malformed("too many guide claims")
                }
                let claimLifecycle = try self.lifecycle(statement, 1, "guide claim lifecycle")
                if lifecycle == .current && claimLifecycle != .current {
                    throw MechanicianHelpError.malformed("current guide claim lifecycle")
                }
                let key = try text(statement, 0, "guide claim key")
                guard Self.isHelpID(key) else {
                    throw MechanicianHelpError.malformed("guide claim key")
                }
                keys.append(key)
            case SQLITE_DONE:
                guard !keys.isEmpty, Set(keys).count == keys.count else {
                    throw MechanicianHelpError.malformed("guide claim grounding")
                }
                return keys
            default:
                throw queryError("read guide claims")
            }
        }
    }

    private func guideSteps(
        id: String,
        surface: MechanicianHelpGuideSurface
    ) throws -> [MechanicianHelpGuideStep] {
        let statement = try prepare("""
            SELECT id, title, instruction, target, reveal_action, completion, ordinal
            FROM help_guide_step
            WHERE guide_id = ?1
            ORDER BY ordinal, id
            LIMIT ?2
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        sqlite3_bind_int(statement, 2, Int32(Self.maximumGuideSteps + 1))
        var steps: [MechanicianHelpGuideStep] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard steps.count < Self.maximumGuideSteps else {
                    throw MechanicianHelpError.malformed("too many guide steps")
                }
                let step = try Self.guideStep(statement, surface: surface)
                guard step.ordinal == steps.count else {
                    throw MechanicianHelpError.malformed("guide step ordinal")
                }
                steps.append(step)
            case SQLITE_DONE:
                guard !steps.isEmpty,
                      Set(steps.map(\.id)).count == steps.count else {
                    throw MechanicianHelpError.malformed("guide steps")
                }
                return steps
            default:
                throw queryError("read guide steps")
            }
        }
    }

    private func demonstration(_ statement: OpaquePointer) throws -> MechanicianHelpDemonstration {
        let id = try text(statement, 0, "demonstration id")
        let articleID = try text(statement, 1, "demonstration article")
        let title = try text(statement, 2, "demonstration title")
        let outcome = try text(statement, 3, "demonstration outcome")
        let lifecycle = try lifecycle(statement, 4, "demonstration lifecycle")
        let ordinal = Int(sqlite3_column_int64(statement, 5))
        guard Self.isHelpID(id),
              Self.isHelpID(articleID),
              id.hasPrefix("\(articleID)."),
              Self.isBoundedNonempty(title, maximumUTF8Bytes: 640),
              Self.isBoundedNonempty(outcome, maximumUTF8Bytes: 2_400),
              ordinal >= 0 else {
            throw MechanicianHelpError.malformed("demonstration identity")
        }
        let recipeJSON = try text(statement, 6, "demonstration recipe")
        guard recipeJSON.utf8.prefix(Self.maximumDemoRecipeUTF8Bytes + 1).count
                <= Self.maximumDemoRecipeUTF8Bytes else {
            throw MechanicianHelpError.malformed("demonstration recipe size")
        }
        guard Self.sha256(recipeJSON) == (try text(statement, 7, "demonstration digest")) else {
            throw MechanicianHelpError.malformed("demonstration digest")
        }
        let recipe = try Self.decodeDemoRecipe(recipeJSON)
        let claimKeys = try demonstrationClaimKeys(id: id, lifecycle: lifecycle)
        try Self.validateDemoRecipe(recipe, demonstrationID: id)
        for fallback in recipe.fallback where fallback.action == .useDemo {
            guard let target = fallback.demoID,
                  target != id,
                  try demonstrationExists(id: target) else {
                throw MechanicianHelpError.malformed("demonstration fallback target")
            }
        }
        return MechanicianHelpDemonstration(
            id: id,
            articleID: articleID,
            title: title,
            outcome: outcome,
            lifecycle: lifecycle,
            ordinal: ordinal,
            claimKeys: claimKeys,
            requirements: recipe.requirements,
            risk: recipe.risk,
            reversibility: recipe.reversibility,
            userConfirmation: recipe.userConfirmation,
            steps: recipe.steps,
            verification: recipe.verification,
            fallback: recipe.fallback,
            evidence: try evidence(demonstrationID: id))
    }

    private func demonstrationClaimKeys(
        id: String,
        lifecycle: MechanicianHelpLifecycle
    ) throws -> [String] {
        let statement = try prepare("""
            SELECT dc.claim_key, c.lifecycle
            FROM help_demo_claim dc
            JOIN help_claim c ON c.key = dc.claim_key
            WHERE dc.demo_id = ?1
            ORDER BY dc.ordinal, dc.claim_key
            LIMIT ?2
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        sqlite3_bind_int(statement, 2, Int32(Self.maximumDemoClaims + 1))
        var keys: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard keys.count < Self.maximumDemoClaims else {
                    throw MechanicianHelpError.malformed("too many demonstration claims")
                }
                let claimLifecycle = try self.lifecycle(
                    statement, 1, "demonstration claim lifecycle")
                if lifecycle == .current && claimLifecycle != .current {
                    throw MechanicianHelpError.malformed("current demonstration claim lifecycle")
                }
                let key = try text(statement, 0, "demonstration claim key")
                guard Self.isHelpID(key) else {
                    throw MechanicianHelpError.malformed("demonstration claim key")
                }
                keys.append(key)
            case SQLITE_DONE:
                guard !keys.isEmpty, Set(keys).count == keys.count else {
                    throw MechanicianHelpError.malformed("demonstration claim grounding")
                }
                return keys
            default:
                throw queryError("read demonstration claims")
            }
        }
    }

    private func demonstrationExists(id: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM help_demo WHERE id = ?1 LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, id)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw queryError("read demonstration fallback")
        }
    }

    func search(_ request: MechanicianHelpSearchRequest) throws -> [MechanicianHelpSearchHit] {
        try search(request, acceptingCompletePrefix: nil)
    }

    /// Provider projections need a stricter contract than the reader UI: once a ranked hit no
    /// longer fits the caller's exact serialized envelope, no lower-ranked hit may fill the hole.
    /// The callback sees each prospective complete prefix before it is admitted; returning false
    /// ends the result immediately, and throwing preserves failures such as an oversized rank one.
    func searchCompleteRankedPrefix(
        _ request: MechanicianHelpSearchRequest,
        acceptingPrefix: @escaping @Sendable ([MechanicianHelpSearchHit]) throws -> Bool
    ) throws -> [MechanicianHelpSearchHit] {
        try search(request, acceptingCompletePrefix: acceptingPrefix)
    }

    /// Resolve an app-selected sequence of current claim keys from the sealed authority. Workflow
    /// demonstration ids are exact selectors, so their signed grounding must not be reconstructed
    /// through fuzzy FTS or silently substituted with a lower-ranked recipe. The caller owns the
    /// serialized-envelope budget through the same complete-prefix contract as provider search.
    func currentClaimHits(
        keys: [String],
        acceptingPrefix: @escaping @Sendable ([MechanicianHelpSearchHit]) throws -> Bool
    ) throws -> [MechanicianHelpSearchHit] {
        guard !keys.isEmpty,
              keys.count <= Self.maximumDemoClaims,
              Set(keys).count == keys.count,
              keys.allSatisfy(Self.isHelpID) else {
            throw MechanicianHelpError.malformed("workflow claim keys")
        }
        var hits: [MechanicianHelpSearchHit] = []
        for (index, key) in keys.enumerated() {
            guard let hit = try searchHit(
                claimKey: key,
                rank: Double(index),
                includeHistory: false
            ) else {
                throw MechanicianHelpError.malformed("workflow claim grounding")
            }
            guard try acceptingPrefix(hits + [hit]) else { return hits }
            hits.append(hit)
        }
        return hits
    }

    private func search(
        _ request: MechanicianHelpSearchRequest,
        acceptingCompletePrefix: (@Sendable ([MechanicianHelpSearchHit]) throws -> Bool)?
    ) throws -> [MechanicianHelpSearchHit] {
        guard let match = Self.matchExpression(for: request.text, mode: request.mode) else {
            return []
        }
        let limit = min(max(request.limit, 1), Self.maximumSearchResults)
        let sortedKinds = request.kinds.sorted { $0.rawValue < $1.rawValue }
        let kindClause: String
        if sortedKinds.isEmpty {
            kindClause = ""
        } else {
            let placeholders = sortedKinds.indices.map { "?\($0 + 4)" }.joined(separator: ", ")
            kindClause = " AND c.kind IN (\(placeholders))"
        }
        let limitIndex = sortedKinds.count + 4
        let statement = try prepare("""
            SELECT f.claim_key,
                   bm25(help_claim_fts, 0.0, 0.0, 10.0, 8.0, 4.0, 1.0) AS rank
            FROM help_claim_fts f
            JOIN help_claim c ON c.key = f.claim_key
            JOIN help_article a ON a.id = c.article_id
            WHERE help_claim_fts MATCH ?1
              AND (?2 = 1 OR (c.lifecycle = 'current' AND a.lifecycle = 'current'))
              \(kindClause)
            ORDER BY CASE COALESCE(NULLIF(a.lifecycle, 'current'), c.lifecycle)
                       WHEN 'current' THEN 0
                       WHEN 'historical' THEN 1
                       WHEN 'superseded' THEN 2
                       WHEN 'retired' THEN 3
                       ELSE 4
                     END,
                     rank,
                     f.rowid
            LIMIT ?\(limitIndex)
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, match)
        sqlite3_bind_int(statement, 2, request.includeHistory ? 1 : 0)
        // Parameter 3 is deliberately reserved for future platform/build applicability without
        // renumbering the kind list in both the agent and reader seams.
        sqlite3_bind_null(statement, 3)
        for (index, kind) in sortedKinds.enumerated() {
            bind(statement, Int32(index + 4), kind.rawValue)
        }
        sqlite3_bind_int(statement, Int32(limitIndex), Int32(limit))

        var candidates: [(String, Double)] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                candidates.append((
                    try text(statement, 0, "search claim key"),
                    sqlite3_column_double(statement, 1)))
            case SQLITE_DONE:
                var hits: [MechanicianHelpSearchHit] = []
                var remainingUTF8Bytes = Self.maximumSearchResultUTF8Bytes
                for (key, rank) in candidates {
                    guard let hit = try searchHit(
                        claimKey: key,
                        rank: rank,
                        includeHistory: request.includeHistory) else { continue }
                    if let acceptingCompletePrefix {
                        guard try acceptingCompletePrefix(hits + [hit]) else { return hits }
                        hits.append(hit)
                        continue
                    }
                    guard let hitSize = Self.utf8Size(
                        of: hit,
                        noMoreThan: remainingUTF8Bytes) else { continue }
                    hits.append(hit)
                    remainingUTF8Bytes -= hitSize
                }
                return hits
            default:
                throw queryError("search")
            }
        }
    }

    /// Test seam proving that the provider and UI share an immutable connection rather than a
    /// writable database whose read-only behavior depends on caller discipline.
    func databaseIsReadOnly() -> Bool {
        sqlite3_db_readonly(database, "main") == 1
    }

    private func searchHit(
        claimKey: String,
        rank: Double,
        includeHistory: Bool
    ) throws -> MechanicianHelpSearchHit? {
        let statement = try prepare("""
            SELECT c.key, c.article_id, c.heading, c.body, c.kind, c.lifecycle, c.ordinal,
                   c.body_sha256,
                   a.id, a.title, a.icon, a.blurb, a.kind, a.lifecycle, a.ordinal, a.section_id
            FROM help_claim c
            JOIN help_article a ON a.id = c.article_id
            WHERE c.key = ?1
            """)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, claimKey)
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return nil
        case SQLITE_ROW:
            let claimLifecycle = try lifecycle(statement, 5, "claim lifecycle")
            let articleLifecycle = try lifecycle(statement, 13, "article lifecycle")
            guard includeHistory
                    || (articleLifecycle == .current && claimLifecycle == .current) else {
                return nil
            }
            let body = try text(statement, 3, "claim body")
            guard Self.sha256(body) == (try text(statement, 7, "claim digest")) else {
                throw MechanicianHelpError.malformed("claim digest")
            }
            let claim = MechanicianHelpClaim(
                key: try text(statement, 0, "claim key"),
                articleID: try text(statement, 1, "claim article"),
                heading: try text(statement, 2, "claim heading"),
                body: body,
                kind: try claimKind(statement, 4, "claim kind"),
                lifecycle: claimLifecycle,
                ordinal: Int(sqlite3_column_int64(statement, 6)))
            let article = MechanicianHelpArticleSummary(
                id: try text(statement, 8, "article id"),
                sectionID: try text(statement, 15, "article section"),
                title: try text(statement, 9, "article title"),
                icon: try text(statement, 10, "article icon"),
                blurb: try text(statement, 11, "article blurb"),
                kind: try claimKind(statement, 12, "article kind"),
                lifecycle: articleLifecycle,
                ordinal: Int(sqlite3_column_int64(statement, 14)))
            guard claim.articleID == article.id else {
                throw MechanicianHelpError.malformed("claim/article identity")
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw MechanicianHelpError.malformed("duplicate claim")
            }
            return MechanicianHelpSearchHit(
                claim: claim,
                article: article,
                evidence: try evidence(claimKey: claim.key),
                // FTS5 returns smaller BM25 values for better matches. Negating gives callers the
                // conventional larger-is-better score without changing the database ordering.
                score: -rank)
        default:
            throw queryError("read search hit")
        }
    }

    private func evidence(articleID: String) throws -> [MechanicianHelpEvidence] {
        try readEvidence(sql: """
            SELECT e.id, e.kind, e.path, e.anchor, e.source_sha256, e.anchor_sha256,
                   min(ce.ordinal) AS evidence_order
            FROM help_claim c
            JOIN help_claim_evidence ce ON ce.claim_key = c.key
            JOIN help_evidence e ON e.id = ce.evidence_id
            WHERE c.article_id = ?1
            GROUP BY e.id
            ORDER BY evidence_order, e.id
            """, value: articleID)
    }

    private func evidence(claimKey: String) throws -> [MechanicianHelpEvidence] {
        try readEvidence(sql: """
            SELECT e.id, e.kind, e.path, e.anchor, e.source_sha256, e.anchor_sha256,
                   ce.ordinal
            FROM help_claim_evidence ce
            JOIN help_evidence e ON e.id = ce.evidence_id
            WHERE ce.claim_key = ?1
            ORDER BY ce.ordinal, e.id
            """, value: claimKey)
    }

    private func evidence(demonstrationID: String) throws -> [MechanicianHelpEvidence] {
        try readEvidence(sql: """
            SELECT e.id, e.kind, e.path, e.anchor, e.source_sha256, e.anchor_sha256,
                   min(dc.ordinal * 1000 + ce.ordinal) AS evidence_order
            FROM help_demo_claim dc
            JOIN help_claim_evidence ce ON ce.claim_key = dc.claim_key
            JOIN help_evidence e ON e.id = ce.evidence_id
            WHERE dc.demo_id = ?1
            GROUP BY e.id
            ORDER BY evidence_order, e.id
            """, value: demonstrationID)
    }

    private func evidence(guideID: String) throws -> [MechanicianHelpEvidence] {
        try readEvidence(sql: """
            SELECT e.id, e.kind, e.path, e.anchor, e.source_sha256, e.anchor_sha256,
                   min(gc.ordinal * 1000 + ce.ordinal) AS evidence_order
            FROM help_guide_claim gc
            JOIN help_claim_evidence ce ON ce.claim_key = gc.claim_key
            JOIN help_evidence e ON e.id = ce.evidence_id
            WHERE gc.guide_id = ?1
            GROUP BY e.id
            ORDER BY evidence_order, e.id
            """, value: guideID)
    }

    private func readEvidence(sql: String, value: String) throws -> [MechanicianHelpEvidence] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        bind(statement, 1, value)
        var rows: [MechanicianHelpEvidence] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let anchor = try text(statement, 3, "evidence anchor")
                let anchorDigest = try text(statement, 5, "evidence anchor digest")
                guard Self.sha256(anchor) == anchorDigest else {
                    throw MechanicianHelpError.malformed("evidence anchor digest")
                }
                let sourceDigest = try text(statement, 4, "evidence source digest")
                guard Self.isSHA256(sourceDigest) else {
                    throw MechanicianHelpError.malformed("evidence source digest")
                }
                rows.append(MechanicianHelpEvidence(
                    id: try text(statement, 0, "evidence id"),
                    kind: try evidenceKind(statement, 1),
                    path: try text(statement, 2, "evidence path"),
                    anchor: anchor,
                    sourceSHA256: sourceDigest,
                    anchorSHA256: anchorDigest))
            case SQLITE_DONE:
                return rows
            default:
                throw queryError("read evidence")
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw queryError("prepare") }
        return statement
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32, _ label: String) throws -> String {
        try Self.text(statement, index, label)
    }

    private func lifecycle(
        _ statement: OpaquePointer,
        _ index: Int32,
        _ label: String
    ) throws -> MechanicianHelpLifecycle {
        guard let value = MechanicianHelpLifecycle(rawValue: try text(statement, index, label)) else {
            throw MechanicianHelpError.malformed(label)
        }
        return value
    }

    private func claimKind(
        _ statement: OpaquePointer,
        _ index: Int32,
        _ label: String
    ) throws -> MechanicianHelpClaimKind {
        guard let value = MechanicianHelpClaimKind(rawValue: try text(statement, index, label)) else {
            throw MechanicianHelpError.malformed(label)
        }
        return value
    }

    private func evidenceKind(
        _ statement: OpaquePointer,
        _ index: Int32
    ) throws -> MechanicianHelpEvidenceKind {
        guard let value = MechanicianHelpEvidenceKind(
            rawValue: try text(statement, index, "evidence kind")) else {
            throw MechanicianHelpError.malformed("evidence kind")
        }
        return value
    }

    private func articleSummary(
        _ statement: OpaquePointer,
        offset: Int32,
        sectionID: String
    ) throws -> MechanicianHelpArticleSummary {
        MechanicianHelpArticleSummary(
            id: try text(statement, offset, "article id"),
            sectionID: sectionID,
            title: try text(statement, offset + 1, "article title"),
            icon: try text(statement, offset + 2, "article icon"),
            blurb: try text(statement, offset + 3, "article blurb"),
            kind: try claimKind(statement, offset + 4, "article kind"),
            lifecycle: try lifecycle(statement, offset + 5, "article lifecycle"),
            ordinal: Int(sqlite3_column_int64(statement, offset + 6)))
    }

    private func queryError(_ operation: String) -> MechanicianHelpError {
        let detail = sqlite3_errmsg(database).map(String.init(cString:)) ?? "unknown SQLite error"
        return .queryFailed("\(operation): \(detail)")
    }

    private static func decodeDemoRecipe(_ json: String) throws -> MechanicianHelpDemoRecipe {
        let data = Data(json.utf8)
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MechanicianHelpError.malformed("demonstration recipe root")
            }
            root = object
        } catch let error as MechanicianHelpError {
            throw error
        } catch {
            throw MechanicianHelpError.malformed("demonstration recipe JSON")
        }
        try requireExactKeys(
            root,
            ["requirements", "risk", "reversibility", "userConfirmation", "steps",
             "verification", "fallback"],
            label: "demonstration recipe")
        guard let requirements = root["requirements"] as? [String: Any] else {
            throw MechanicianHelpError.malformed("demonstration requirements")
        }
        try requireExactKeys(
            requirements, ["session", "mode", "tools"], label: "demonstration requirements")
        guard let reversibility = root["reversibility"] as? [String: Any] else {
            throw MechanicianHelpError.malformed("demonstration reversibility")
        }
        try requireExactKeys(
            reversibility, ["kind", "instructions"], label: "demonstration reversibility")
        guard let steps = root["steps"] as? [[String: Any]],
              !steps.isEmpty,
              steps.count <= maximumDemoSteps else {
            throw MechanicianHelpError.malformed("demonstration steps")
        }
        for step in steps {
            guard let kind = step["kind"] as? String else {
                throw MechanicianHelpError.malformed("demonstration step kind")
            }
            let keys: Set<String> = (kind == "observe" || kind == "act")
                ? ["id", "kind", "tool", "instruction"]
                : ["id", "kind", "instruction"]
            try requireExactKeys(step, keys, label: "demonstration step")
        }
        guard let verification = root["verification"] as? [[String: Any]],
              !verification.isEmpty,
              verification.count <= maximumDemoVerification else {
            throw MechanicianHelpError.malformed("demonstration verification")
        }
        for item in verification {
            try requireExactKeys(
                item,
                ["kind", "stepID", "instruction"],
                label: "demonstration verification")
        }
        guard let fallback = root["fallback"] as? [[String: Any]],
              !fallback.isEmpty,
              fallback.count <= maximumDemoFallback else {
            throw MechanicianHelpError.malformed("demonstration fallback")
        }
        for item in fallback {
            guard let action = item["action"] as? String else {
                throw MechanicianHelpError.malformed("demonstration fallback action")
            }
            let keys: Set<String> = action == "useDemo"
                ? ["when", "action", "demoID", "instruction"]
                : ["when", "action", "instruction"]
            try requireExactKeys(item, keys, label: "demonstration fallback")
        }
        do {
            return try JSONDecoder().decode(MechanicianHelpDemoRecipe.self, from: data)
        } catch {
            throw MechanicianHelpError.malformed("demonstration recipe values")
        }
    }

    private static func requireExactKeys(
        _ object: [String: Any],
        _ expected: Set<String>,
        label: String
    ) throws {
        guard Set(object.keys) == expected else {
            throw MechanicianHelpError.malformed("\(label) keys")
        }
    }

    private static func validateDemoRecipe(
        _ recipe: MechanicianHelpDemoRecipe,
        demonstrationID: String
    ) throws {
        let tools = recipe.requirements.tools
        guard !tools.isEmpty,
              tools.count <= maximumDemoTools,
              Set(tools).count == tools.count,
              Set(tools).isSubset(of: Set(demoToolPolicies.keys)) else {
            throw MechanicianHelpError.malformed("demonstration tools")
        }
        guard !recipe.steps.isEmpty,
              recipe.steps.count <= maximumDemoSteps,
              Set(recipe.steps.map(\.id)).count == recipe.steps.count,
              recipe.steps.allSatisfy({ isHelpID($0.id) && !$0.instruction.isEmpty }) else {
            throw MechanicianHelpError.malformed("demonstration steps")
        }
        var usedTools = Set<String>()
        for step in recipe.steps {
            switch step.kind {
            case .observe, .act:
                guard let tool = step.tool,
                      tools.contains(tool),
                      let policy = demoToolPolicies[tool] else {
                    throw MechanicianHelpError.malformed("demonstration step tool")
                }
                guard step.kind == policy.stepKind else {
                    throw MechanicianHelpError.malformed("demonstration tool step class")
                }
                usedTools.insert(tool)
            case .ask, .explain:
                guard step.tool == nil else {
                    throw MechanicianHelpError.malformed("demonstration non-tool step")
                }
            }
        }
        guard usedTools == Set(tools) else {
            throw MechanicianHelpError.malformed("demonstration unused tool")
        }
        let actionEffects = Set(tools.compactMap { tool -> DemoToolEffect? in
            guard let effect = demoToolPolicies[tool]?.effect,
                  effect != .inventory else { return nil }
            return effect
        })
        guard actionEffects.count <= 1 else {
            throw MechanicianHelpError.malformed("demonstration incompatible tool classes")
        }
        let effect = actionEffects.first ?? .inventory
        let hasCanonicalToolContract: Bool
        switch effect {
        case .inventory:
            hasCanonicalToolContract = recipe.requirements.mode == .readOnlyOkay
                && recipe.risk == .readOnly
                && recipe.reversibility.kind == .notNeeded
                && recipe.userConfirmation == .none
        case .externalDynamic:
            hasCanonicalToolContract = recipe.requirements.mode == .executionEnabled
                && recipe.risk == .dynamic
                && recipe.reversibility.kind == .dynamic
                && recipe.userConfirmation == .beforeAct
        case .inAppAdditive:
            hasCanonicalToolContract = recipe.requirements.mode == .planCompatibleAction
                && recipe.risk == .additive
                && recipe.reversibility.kind == .manual
                && recipe.userConfirmation == .beforeDemo
        }
        guard hasCanonicalToolContract else {
            throw MechanicianHelpError.malformed("demonstration tool class contract")
        }
        let actStepIDs = Set(recipe.steps.filter { $0.kind == .act }.map(\.id))
        let hasAct = !actStepIDs.isEmpty
        guard hasAct == (recipe.requirements.mode != .readOnlyOkay) else {
            throw MechanicianHelpError.malformed("demonstration execution mode")
        }
        if hasAct && recipe.userConfirmation == .none {
            throw MechanicianHelpError.malformed("demonstration confirmation")
        }
        if recipe.userConfirmation == .beforeAct && !hasAct {
            throw MechanicianHelpError.malformed("demonstration confirmation")
        }
        if recipe.risk == .readOnly {
            guard !hasAct,
                  recipe.reversibility.kind == .notNeeded,
                  recipe.userConfirmation == .none else {
                throw MechanicianHelpError.malformed("demonstration read-only contract")
            }
        }
        if recipe.risk == .dynamic && recipe.reversibility.kind != .dynamic {
            throw MechanicianHelpError.malformed("demonstration dynamic contract")
        }
        if recipe.risk == .reversibleLocal,
           recipe.reversibility.kind != .automatic,
           recipe.reversibility.kind != .manual {
            throw MechanicianHelpError.malformed("demonstration reversible contract")
        }
        guard !recipe.reversibility.instructions.isEmpty else {
            throw MechanicianHelpError.malformed("demonstration reversibility instructions")
        }

        let stepIDs = Set(recipe.steps.map(\.id))
        guard !recipe.verification.isEmpty,
              recipe.verification.count <= maximumDemoVerification,
              recipe.verification.allSatisfy({
                  stepIDs.contains($0.stepID) && !$0.instruction.isEmpty
              }) else {
            throw MechanicianHelpError.malformed("demonstration verification")
        }
        for item in recipe.verification where item.kind == .toolSucceeded {
            guard recipe.steps.first(where: { $0.id == item.stepID })?.tool != nil else {
                throw MechanicianHelpError.malformed("demonstration tool verification")
            }
        }
        if hasAct && !recipe.verification.contains(where: { actStepIDs.contains($0.stepID) }) {
            throw MechanicianHelpError.malformed("demonstration post-action verification")
        }

        guard !recipe.fallback.isEmpty,
              recipe.fallback.count <= maximumDemoFallback,
              Set(recipe.fallback.map(\.when)).count == recipe.fallback.count else {
            throw MechanicianHelpError.malformed("demonstration fallback")
        }
        for fallback in recipe.fallback {
            guard !fallback.instruction.isEmpty else {
                throw MechanicianHelpError.malformed("demonstration fallback instruction")
            }
            switch fallback.action {
            case .explain:
                guard fallback.demoID == nil else {
                    throw MechanicianHelpError.malformed("demonstration fallback target")
                }
            case .useDemo:
                guard let target = fallback.demoID,
                      isHelpID(target),
                      target != demonstrationID else {
                    throw MechanicianHelpError.malformed("demonstration fallback target")
                }
            }
        }
    }

    private static func guideStep(
        _ statement: OpaquePointer,
        surface: MechanicianHelpGuideSurface,
        offset: Int32 = 0
    ) throws -> MechanicianHelpGuideStep {
        let id = try text(statement, offset, "guide step id")
        let title = try text(statement, offset + 1, "guide step title")
        let instruction = try text(statement, offset + 2, "guide step instruction")
        guard let target = MechanicianHelpGuideTarget(
                rawValue: try text(statement, offset + 3, "guide step target")),
              let revealAction = MechanicianHelpGuideRevealAction(
                rawValue: try text(statement, offset + 4, "guide step reveal action")),
              let completion = MechanicianHelpGuideCompletion(
                rawValue: try text(statement, offset + 5, "guide step completion")) else {
            throw MechanicianHelpError.malformed("guide step vocabulary")
        }
        let ordinal = Int(sqlite3_column_int64(statement, offset + 6))
        guard isHelpID(id),
              isGuideCopy(title, maximumUTF16Units: 160, maximumUTF8Bytes: 640),
              isGuideCopy(
                instruction,
                maximumUTF16Units: 1_000,
                maximumUTF8Bytes: 4_000),
              ordinal >= 0 else {
            throw MechanicianHelpError.malformed("guide step identity")
        }
        if revealAction != .none,
           guideRevealTargets[revealAction]?.contains(target) != true {
            throw MechanicianHelpError.malformed("guide reveal target")
        }
        guard guideSurfaceTargets[surface]?.contains(target) == true else {
            throw MechanicianHelpError.malformed("guide surface target")
        }
        guard guideSurfaceRevealActions[surface]?.contains(revealAction) == true else {
            throw MechanicianHelpError.malformed("guide surface reveal action")
        }
        if completion == .textEntered, target != .helpSearchField {
            throw MechanicianHelpError.malformed("guide completion target")
        }
        return MechanicianHelpGuideStep(
            id: id,
            title: title,
            instruction: instruction,
            target: target,
            revealAction: revealAction,
            completion: completion,
            ordinal: ordinal)
    }

    private static func isGuideCopy(
        _ value: String,
        maximumUTF16Units: Int,
        maximumUTF8Bytes: Int
    ) -> Bool {
        guard isBoundedNonempty(value, maximumUTF8Bytes: maximumUTF8Bytes),
              value.utf16.count <= maximumUTF16Units,
              !value.contains("\0"),
              value == value.precomposedStringWithCanonicalMapping else { return false }
        let patterns = [
            #"\b[a-z][a-z0-9+.-]{1,31}://"#,
            #"\b[a-z][a-z0-9+.-]{1,31}:(?=[^\s])"#,
            #"\b(?:javascript|data|file):"#,
            #"\b(?:osascript|applescript|jxa|javascript|shell\s+script|bash|zsh)\b|#!"#,
            #"\b(?:python(?:\d+(?:\.\d+)?)?|ruby|perl|node|php|swift|sh|fish|pwsh|powershell|cmd(?:\.exe)?)\s+(?:-[a-z]|/[a-z]|--(?:eval|execute)\b)"#,
            #"\b(?:css|xpath|accessibility)\s+selector\b|\[[a-z][\w-]*(?:[~|^$*]?=)[^\]]+\]|#[a-z][\w-]{2,}"#,
            #"\b[a-z][\w-]*:(?:nth-(?:child|last-child|of-type|last-of-type)|first-child|last-child|only-child|only-of-type|not|has|is|where)\s*(?:\([^)]*\))?"#,
            #"\bax(?:role|title|identifier|description|value)\s*(?:==?|~=|\^=|\$=|\*=)"#,
            #"\b[xy]\s*[:=]\s*-?\d|\(\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*\)"#,
            #"\b(?:click|tap|point(?:\s+at)?|position|coordinates?)\s+(?:at\s+)?-?\d+(?:\.\d+)?\s*[,/]\s*-?\d+(?:\.\d+)?\b"#,
            #"\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b"#,
            #"\b(?:workspace|window|conversation)(?:\s+|[-_.])?(?:id|identifier)\b"#,
            #"\b(?:delete|remove|rename|move|create|edit|modify|write|send|submit|run|execute|install|uninstall|enable|disable|toggle|change)\s+(?:the|this|a|an|your|its|memory|workspace|conversation|window|page|setting|value|file|message|app|control)\b"#,
        ]
        return patterns.allSatisfy {
            value.range(of: $0, options: [.regularExpression, .caseInsensitive]) == nil
        }
    }

    private static func isHelpID(_ value: String) -> Bool {
        value.range(
            of: #"^[a-z0-9][a-z0-9.-]{0,95}$"#,
            options: .regularExpression) != nil
    }

    private static func isBoundedNonempty(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.prefix(maximumUTF8Bytes + 1).count <= maximumUTF8Bytes
    }

    private static func readMetadata(_ database: OpaquePointer) throws -> MechanicianHelpMetadata {
        let statement = try prepare(database, """
            SELECT corpus_schema, corpus_id, application_version, application_build,
                   bundle_identifier, tenant_id, source_commit, source_diff_sha256, content_sha256
            FROM help_meta
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MechanicianHelpError.malformed("missing metadata")
        }
        let metadata = MechanicianHelpMetadata(
            schemaVersion: Int(sqlite3_column_int64(statement, 0)),
            corpusID: try text(statement, 1, "corpus id"),
            applicationVersion: try text(statement, 2, "application version"),
            applicationBuild: try text(statement, 3, "application build"),
            bundleIdentifier: try text(statement, 4, "bundle identifier"),
            tenantID: try text(statement, 5, "tenant id"),
            sourceCommit: try text(statement, 6, "source commit"),
            sourceDiffSHA256: try text(statement, 7, "source diff digest"),
            contentSHA256: try text(statement, 8, "content digest"))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MechanicianHelpError.malformed("duplicate metadata")
        }
        return metadata
    }

    private static func validate(
        metadata: MechanicianHelpMetadata,
        expectedBuild: MechanicianHelpBuildIdentity?
    ) throws {
        guard metadata.schemaVersion == schemaVersion,
              !metadata.corpusID.isEmpty,
              metadata.sourceCommit.count == 40,
              metadata.sourceCommit.allSatisfy({ $0.isHexDigit }),
              isSHA256(metadata.sourceDiffSHA256),
              isSHA256(metadata.contentSHA256) else {
            throw MechanicianHelpError.malformed("metadata")
        }
        guard let expectedBuild else { return }
        let comparisons: [(Bool, String)] = [
            (metadata.applicationVersion == expectedBuild.applicationVersion, "application version"),
            (metadata.applicationBuild == expectedBuild.applicationBuild, "application build"),
            (metadata.bundleIdentifier == expectedBuild.bundleIdentifier, "bundle identifier"),
            (expectedBuild.tenantID.map { metadata.tenantID == $0 } ?? true, "tenant"),
            (expectedBuild.sourceCommit.map { metadata.sourceCommit == $0 } ?? true, "source commit"),
            (expectedBuild.sourceDiffSHA256.map {
                metadata.sourceDiffSHA256 == $0
            } ?? true, "source diff"),
        ]
        if let mismatch = comparisons.first(where: { !$0.0 })?.1 {
            throw MechanicianHelpError.buildMismatch(mismatch)
        }
    }

    private static func validatePackagedArtifact(
        databaseURL: URL,
        expectedBuild: MechanicianHelpBuildIdentity?
    ) throws {
        guard let expectedBuild else { return }
        if let expectedSchema = expectedBuild.helpCorpusSchemaVersion,
           expectedSchema != schemaVersion {
            throw MechanicianHelpError.buildMismatch("corpus schema")
        }
        guard let expectedDigest = expectedBuild.helpCorpusSHA256 else { return }
        guard isSHA256(expectedDigest),
              try fileSHA256(databaseURL) == expectedDigest else {
            throw MechanicianHelpError.buildMismatch("corpus digest")
        }
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        guard url.isFileURL else { throw MechanicianHelpError.cannotOpen }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while let bytes = try handle.read(upToCount: 1_024 * 1_024), !bytes.isEmpty {
                digest.update(data: bytes)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        } catch let error as MechanicianHelpError {
            throw error
        } catch {
            throw MechanicianHelpError.cannotOpen
        }
    }

    private static func validateSchema(_ database: OpaquePointer) throws {
        let expectedObjects: [String: SchemaObject] = [
            "help_meta": SchemaObject(
                type: "table", columnCount: 10, withoutRowID: false, strict: true),
            "help_section": SchemaObject(
                type: "table", columnCount: 3, withoutRowID: true, strict: true),
            "help_article": SchemaObject(
                type: "table", columnCount: 10, withoutRowID: true, strict: true),
            "help_article_alias": SchemaObject(
                type: "table", columnCount: 3, withoutRowID: true, strict: true),
            "help_claim": SchemaObject(
                type: "table", columnCount: 8, withoutRowID: true, strict: true),
            "help_evidence": SchemaObject(
                type: "table", columnCount: 6, withoutRowID: true, strict: true),
            "help_claim_evidence": SchemaObject(
                type: "table", columnCount: 3, withoutRowID: true, strict: true),
            "help_relation": SchemaObject(
                type: "table", columnCount: 3, withoutRowID: true, strict: true),
            "help_demo": SchemaObject(
                type: "table", columnCount: 8, withoutRowID: true, strict: true),
            "help_demo_claim": SchemaObject(
                type: "table", columnCount: 3, withoutRowID: true, strict: true),
            "help_guide": SchemaObject(
                type: "table", columnCount: 7, withoutRowID: true, strict: true),
            "help_guide_claim": SchemaObject(
                type: "table", columnCount: 3, withoutRowID: true, strict: true),
            "help_guide_step": SchemaObject(
                type: "table", columnCount: 8, withoutRowID: true, strict: true),
            "help_claim_fts": SchemaObject(
                type: "virtual", columnCount: 8, withoutRowID: false, strict: false),
            "help_claim_fts_data": SchemaObject(
                type: "shadow", columnCount: 2, withoutRowID: false, strict: false),
            "help_claim_fts_idx": SchemaObject(
                type: "shadow", columnCount: 3, withoutRowID: true, strict: false),
            "help_claim_fts_content": SchemaObject(
                type: "shadow", columnCount: 7, withoutRowID: false, strict: false),
            "help_claim_fts_docsize": SchemaObject(
                type: "shadow", columnCount: 2, withoutRowID: false, strict: false),
            "help_claim_fts_config": SchemaObject(
                type: "shadow", columnCount: 2, withoutRowID: true, strict: false),
            "help_article_fts": SchemaObject(
                type: "virtual", columnCount: 7, withoutRowID: false, strict: false),
            "help_article_fts_data": SchemaObject(
                type: "shadow", columnCount: 2, withoutRowID: false, strict: false),
            "help_article_fts_idx": SchemaObject(
                type: "shadow", columnCount: 3, withoutRowID: true, strict: false),
            "help_article_fts_content": SchemaObject(
                type: "shadow", columnCount: 6, withoutRowID: false, strict: false),
            "help_article_fts_docsize": SchemaObject(
                type: "shadow", columnCount: 2, withoutRowID: false, strict: false),
            "help_article_fts_config": SchemaObject(
                type: "shadow", columnCount: 2, withoutRowID: true, strict: false),
        ]
        let objectStatement = try prepare(database, """
            SELECT name, type, ncol, wr, strict
            FROM pragma_table_list
            WHERE schema = 'main' AND substr(name, 1, 7) != 'sqlite_'
            ORDER BY name
        """)
        defer { sqlite3_finalize(objectStatement) }
        var foundObjects: [String: SchemaObject] = [:]
        objectRows: while true {
            switch sqlite3_step(objectStatement) {
            case SQLITE_ROW:
                let name = try text(objectStatement, 0, "schema object name")
                guard foundObjects[name] == nil else {
                    throw MechanicianHelpError.malformed("duplicate schema object")
                }
                foundObjects[name] = SchemaObject(
                    type: try text(objectStatement, 1, "schema object type"),
                    columnCount: Int(sqlite3_column_int64(objectStatement, 2)),
                    withoutRowID: sqlite3_column_int(objectStatement, 3) == 1,
                    strict: sqlite3_column_int(objectStatement, 4) == 1)
            case SQLITE_DONE:
                guard foundObjects == expectedObjects else {
                    throw MechanicianHelpError.malformed("schema objects")
                }
                break objectRows
            default:
                throw MechanicianHelpError.queryFailed("schema object query")
            }
        }

        let columns: [String: [SchemaColumn]] = [
            "help_meta": [
                column("id", "INTEGER", notNull: false, primaryKey: 1),
                column("corpus_schema", "INTEGER"), column("corpus_id", "TEXT"),
                column("application_version", "TEXT"), column("application_build", "TEXT"),
                column("bundle_identifier", "TEXT"), column("tenant_id", "TEXT"),
                column("source_commit", "TEXT"), column("source_diff_sha256", "TEXT"),
                column("content_sha256", "TEXT"),
            ],
            "help_section": [
                column("id", "TEXT", primaryKey: 1), column("title", "TEXT"),
                column("ordinal", "INTEGER"),
            ],
            "help_article": [
                column("id", "TEXT", primaryKey: 1), column("section_id", "TEXT"),
                column("title", "TEXT"), column("icon", "TEXT"), column("blurb", "TEXT"),
                column("kind", "TEXT"), column("lifecycle", "TEXT"),
                column("ordinal", "INTEGER"), column("markdown", "TEXT"),
                column("body_sha256", "TEXT"),
            ],
            "help_article_alias": [
                column("article_id", "TEXT", primaryKey: 1),
                column("alias", "TEXT", primaryKey: 2), column("ordinal", "INTEGER"),
            ],
            "help_claim": [
                column("key", "TEXT", primaryKey: 1), column("article_id", "TEXT"),
                column("heading", "TEXT"), column("body", "TEXT"), column("kind", "TEXT"),
                column("lifecycle", "TEXT"), column("ordinal", "INTEGER"),
                column("body_sha256", "TEXT"),
            ],
            "help_evidence": [
                column("id", "TEXT", primaryKey: 1), column("kind", "TEXT"),
                column("path", "TEXT"), column("anchor", "TEXT"),
                column("source_sha256", "TEXT"), column("anchor_sha256", "TEXT"),
            ],
            "help_claim_evidence": [
                column("claim_key", "TEXT", primaryKey: 1),
                column("evidence_id", "TEXT", primaryKey: 2), column("ordinal", "INTEGER"),
            ],
            "help_relation": [
                column("source_claim_key", "TEXT", primaryKey: 1),
                column("target_claim_key", "TEXT", primaryKey: 2),
                column("kind", "TEXT", primaryKey: 3),
            ],
            "help_demo": [
                column("id", "TEXT", primaryKey: 1), column("article_id", "TEXT"),
                column("title", "TEXT"), column("outcome", "TEXT"),
                column("lifecycle", "TEXT"), column("ordinal", "INTEGER"),
                column("recipe_json", "TEXT"), column("recipe_sha256", "TEXT"),
            ],
            "help_demo_claim": [
                column("demo_id", "TEXT", primaryKey: 1),
                column("claim_key", "TEXT", primaryKey: 2), column("ordinal", "INTEGER"),
            ],
            "help_guide": [
                column("id", "TEXT", primaryKey: 1), column("article_id", "TEXT"),
                column("title", "TEXT"), column("summary", "TEXT"),
                column("surface", "TEXT"),
                column("lifecycle", "TEXT"), column("ordinal", "INTEGER"),
            ],
            "help_guide_claim": [
                column("guide_id", "TEXT", primaryKey: 1),
                column("claim_key", "TEXT", primaryKey: 2), column("ordinal", "INTEGER"),
            ],
            "help_guide_step": [
                column("guide_id", "TEXT", primaryKey: 1),
                column("id", "TEXT", primaryKey: 2), column("title", "TEXT"),
                column("instruction", "TEXT"), column("target", "TEXT"),
                column("reveal_action", "TEXT"), column("completion", "TEXT"),
                column("ordinal", "INTEGER"),
            ],
            "help_claim_fts": [
                column("claim_key", "", notNull: false),
                column("article_id", "", notNull: false),
                column("title", "", notNull: false), column("aliases", "", notNull: false),
                column("heading", "", notNull: false), column("body", "", notNull: false),
                column("help_claim_fts", "", notNull: false, hidden: 1),
                column("rank", "", notNull: false, hidden: 1),
            ],
            "help_article_fts": [
                column("article_id", "", notNull: false),
                column("title", "", notNull: false), column("aliases", "", notNull: false),
                column("blurb", "", notNull: false), column("markdown", "", notNull: false),
                column("help_article_fts", "", notNull: false, hidden: 1),
                column("rank", "", notNull: false, hidden: 1),
            ],
        ]
        for (table, expectedColumns) in columns {
            guard try tableColumns(database, table: table) == expectedColumns else {
                throw MechanicianHelpError.malformed("schema columns \(table)")
            }
        }
        for table in ["help_claim_fts", "help_article_fts"] {
            let statement = try prepare(database, """
                SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = '\(table)'
                """)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw MechanicianHelpError.malformed("FTS5 schema \(table)")
            }
            let sql = try text(statement, 0, "FTS5 schema")
            let normalized = sql
                .filter { !$0.isWhitespace }
                .lowercased()
            guard normalized.hasPrefix("createvirtualtable\(table)usingfts5("),
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw MechanicianHelpError.malformed("FTS5 schema \(table)")
            }
        }
    }

    private static func column(
        _ name: String,
        _ type: String,
        notNull: Bool = true,
        primaryKey: Int = 0,
        hidden: Int = 0
    ) -> SchemaColumn {
        SchemaColumn(
            name: name,
            type: type,
            notNull: notNull,
            primaryKeyPosition: primaryKey,
            hidden: hidden)
    }

    private static func tableColumns(
        _ database: OpaquePointer,
        table: String
    ) throws -> [SchemaColumn] {
        let statement = try prepare(database, """
            SELECT name, type, "notnull", dflt_value, pk, hidden
            FROM pragma_table_xinfo('\(table)')
            ORDER BY cid
            """)
        defer { sqlite3_finalize(statement) }
        var columns: [SchemaColumn] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard sqlite3_column_type(statement, 3) == SQLITE_NULL else {
                    throw MechanicianHelpError.malformed("schema default \(table)")
                }
                columns.append(SchemaColumn(
                    name: try text(statement, 0, "schema column name"),
                    type: try text(statement, 1, "schema column type"),
                    notNull: sqlite3_column_int(statement, 2) == 1,
                    primaryKeyPosition: Int(sqlite3_column_int64(statement, 4)),
                    hidden: Int(sqlite3_column_int64(statement, 5))))
            case SQLITE_DONE:
                return columns
            default:
                throw MechanicianHelpError.queryFailed("schema column query")
            }
        }
    }

    private static func validateVocabulary(_ database: OpaquePointer) throws {
        let lifecycleRows = try distinctValues(database, sql: """
            SELECT lifecycle FROM help_article
            UNION
            SELECT lifecycle FROM help_claim
            UNION
            SELECT lifecycle FROM help_demo
            UNION
            SELECT lifecycle FROM help_guide
            """)
        let lifecycles = Set(MechanicianHelpLifecycle.allCases.map(\.rawValue))
        guard lifecycleRows.isSubset(of: lifecycles) else {
            throw MechanicianHelpError.malformed("lifecycle vocabulary")
        }
        let kindRows = try distinctValues(database, sql: """
            SELECT kind FROM help_article
            UNION
            SELECT kind FROM help_claim
            """)
        let kinds = Set(MechanicianHelpClaimKind.allCases.map(\.rawValue))
        guard kindRows.isSubset(of: kinds) else {
            throw MechanicianHelpError.malformed("claim-kind vocabulary")
        }
        let evidenceRows = try distinctValues(database, sql: "SELECT kind FROM help_evidence")
        let evidenceKinds = Set(MechanicianHelpEvidenceKind.allCases.map(\.rawValue))
        guard evidenceRows.isSubset(of: evidenceKinds) else {
            throw MechanicianHelpError.malformed("evidence-kind vocabulary")
        }
    }

    private static func validateCurrentClaimEvidence(_ database: OpaquePointer) throws {
        let statement = try prepare(database, """
            SELECT c.key
            FROM help_claim c
            WHERE c.lifecycle = 'current'
              AND NOT EXISTS (
                SELECT 1 FROM help_claim_evidence ce WHERE ce.claim_key = c.key
              )
            LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MechanicianHelpError.malformed("current claim evidence")
        }
    }

    private static func validateCurrentDemonstrationGrounding(
        _ database: OpaquePointer
    ) throws {
        guard try scalarCount(database, "SELECT count(*) FROM help_demo") > 0 else {
            throw MechanicianHelpError.malformed("missing demonstrations")
        }
        let statement = try prepare(database, """
            SELECT d.id
            FROM help_demo d
            JOIN help_article a ON a.id = d.article_id
            WHERE NOT EXISTS (
                    SELECT 1 FROM help_demo_claim dc WHERE dc.demo_id = d.id
                  )
               OR (d.lifecycle = 'current' AND (
                    a.lifecycle != 'current'
                    OR EXISTS (
                        SELECT 1
                        FROM help_demo_claim dc
                        JOIN help_claim c ON c.key = dc.claim_key
                        WHERE dc.demo_id = d.id AND c.lifecycle != 'current'
                    )
                  ))
            LIMIT 1
            """)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw MechanicianHelpError.malformed("demonstration claim grounding")
        }
    }

    private static func validateGuideAuthority(_ database: OpaquePointer) throws {
        let guideCount = try scalarCount(database, "SELECT count(*) FROM help_guide")
        guard guideCount > 0, guideCount <= maximumGuides else {
            throw MechanicianHelpError.malformed("guide count")
        }
        let oversizedArticle = try prepare(database, """
            SELECT article_id FROM help_guide
            GROUP BY article_id HAVING count(*) > \(maximumGuidesPerArticle)
            LIMIT 1
            """)
        defer { sqlite3_finalize(oversizedArticle) }
        guard sqlite3_step(oversizedArticle) == SQLITE_DONE else {
            throw MechanicianHelpError.malformed("too many article guides")
        }
        let grounding = try prepare(database, """
            SELECT g.id
            FROM help_guide g
            JOIN help_article a ON a.id = g.article_id
            WHERE (SELECT count(*) FROM help_guide_claim gc WHERE gc.guide_id = g.id)
                    NOT BETWEEN 1 AND \(maximumGuideClaims)
               OR (SELECT count(*) FROM help_guide_step gs WHERE gs.guide_id = g.id)
                    NOT BETWEEN 1 AND \(maximumGuideSteps)
               OR (g.lifecycle = 'current' AND (
                    a.lifecycle != 'current'
                    OR EXISTS (
                        SELECT 1
                        FROM help_guide_claim gc
                        JOIN help_claim c ON c.key = gc.claim_key
                        WHERE gc.guide_id = g.id AND c.lifecycle != 'current'
                    )
                  ))
            LIMIT 1
            """)
        defer { sqlite3_finalize(grounding) }
        guard sqlite3_step(grounding) == SQLITE_DONE else {
            throw MechanicianHelpError.malformed("guide claim grounding")
        }

        let guides = try prepare(database, """
            SELECT id, article_id, title, summary, surface, lifecycle, ordinal
            FROM help_guide ORDER BY id
            """)
        defer { sqlite3_finalize(guides) }
        guideRows: while true {
            switch sqlite3_step(guides) {
            case SQLITE_ROW:
                let id = try text(guides, 0, "guide id")
                let articleID = try text(guides, 1, "guide article")
                guard isHelpID(id),
                      isHelpID(articleID),
                      id.hasPrefix("\(articleID)."),
                      isGuideCopy(
                        try text(guides, 2, "guide title"),
                        maximumUTF16Units: 160,
                        maximumUTF8Bytes: 640),
                      isGuideCopy(
                        try text(guides, 3, "guide summary"),
                        maximumUTF16Units: 600,
                        maximumUTF8Bytes: 2_400),
                      MechanicianHelpGuideSurface(
                        rawValue: try text(guides, 4, "guide surface")) != nil,
                      MechanicianHelpLifecycle(
                        rawValue: try text(guides, 5, "guide lifecycle")) != nil,
                      sqlite3_column_int64(guides, 6) >= 0 else {
                    throw MechanicianHelpError.malformed("guide identity")
                }
            case SQLITE_DONE:
                break guideRows
            default:
                throw MechanicianHelpError.queryFailed("guide authority query")
            }
        }

        let claims = try prepare(database, """
            SELECT guide_id, claim_key, ordinal
            FROM help_guide_claim ORDER BY guide_id, ordinal, claim_key
            """)
        defer { sqlite3_finalize(claims) }
        var expectedClaimOrdinalByGuide: [String: Int] = [:]
        claimRows: while true {
            switch sqlite3_step(claims) {
            case SQLITE_ROW:
                let guideID = try text(claims, 0, "guide claim guide")
                let claimKey = try text(claims, 1, "guide claim key")
                let ordinal = Int(sqlite3_column_int64(claims, 2))
                let expectedOrdinal = expectedClaimOrdinalByGuide[guideID, default: 0]
                guard isHelpID(guideID),
                      isHelpID(claimKey),
                      ordinal == expectedOrdinal else {
                    throw MechanicianHelpError.malformed("guide claim identity")
                }
                expectedClaimOrdinalByGuide[guideID] = expectedOrdinal + 1
            case SQLITE_DONE:
                break claimRows
            default:
                throw MechanicianHelpError.queryFailed("guide claim authority query")
            }
        }

        let steps = try prepare(database, """
            SELECT gs.guide_id, gs.id, gs.title, gs.instruction, gs.target,
                   gs.reveal_action, gs.completion, gs.ordinal, g.surface
            FROM help_guide_step gs
            JOIN help_guide g ON g.id = gs.guide_id
            ORDER BY gs.guide_id, gs.ordinal, gs.id
            """)
        defer { sqlite3_finalize(steps) }
        var expectedOrdinalByGuide: [String: Int] = [:]
        while true {
            switch sqlite3_step(steps) {
            case SQLITE_ROW:
                let guideID = try text(steps, 0, "guide step guide")
                guard isHelpID(guideID) else {
                    throw MechanicianHelpError.malformed("guide step guide")
                }
                guard let surface = MechanicianHelpGuideSurface(
                    rawValue: try text(steps, 8, "guide step surface")) else {
                    throw MechanicianHelpError.malformed("guide surface")
                }
                let step = try guideStep(steps, surface: surface, offset: 1)
                let expectedOrdinal = expectedOrdinalByGuide[guideID, default: 0]
                guard step.ordinal == expectedOrdinal else {
                    throw MechanicianHelpError.malformed("guide step ordinal")
                }
                expectedOrdinalByGuide[guideID] = expectedOrdinal + 1
            case SQLITE_DONE:
                return
            default:
                throw MechanicianHelpError.queryFailed("guide step authority query")
            }
        }
    }

    private static func validateFTSParity(_ database: OpaquePointer) throws {
        let articleCount = try scalarCount(database, "SELECT count(*) FROM help_article")
        let articleFTSCount = try scalarCount(database, "SELECT count(*) FROM help_article_fts")
        let claimCount = try scalarCount(database, "SELECT count(*) FROM help_claim")
        let claimFTSCount = try scalarCount(database, "SELECT count(*) FROM help_claim_fts")
        guard articleCount > 0,
              claimCount > 0,
              articleCount == articleFTSCount,
              claimCount == claimFTSCount else {
            throw MechanicianHelpError.malformed("FTS parity")
        }
        let articleMismatch = try prepare(database, """
            SELECT 1
            FROM help_article_fts f
            LEFT JOIN help_article a ON a.id = f.article_id
            WHERE a.id IS NULL
               OR f.title IS NOT a.title
               OR f.aliases IS NOT COALESCE((
                    SELECT group_concat(ordered_alias.alias, ' ')
                    FROM (
                        SELECT aa.alias
                        FROM help_article_alias aa
                        WHERE aa.article_id = a.id
                        ORDER BY aa.ordinal, aa.alias
                    ) ordered_alias
                  ), '')
               OR f.blurb IS NOT a.blurb
               OR f.markdown IS NOT a.markdown
            UNION ALL
            SELECT 1
            FROM help_article a
            LEFT JOIN help_article_fts f ON f.article_id = a.id
            GROUP BY a.id
            HAVING count(f.rowid) != 1
            LIMIT 1
            """)
        defer { sqlite3_finalize(articleMismatch) }
        guard sqlite3_step(articleMismatch) == SQLITE_DONE else {
            throw MechanicianHelpError.malformed("article FTS parity")
        }
        let claimMismatch = try prepare(database, """
            SELECT 1
            FROM help_claim_fts f
            LEFT JOIN help_claim c ON c.key = f.claim_key
            LEFT JOIN help_article a ON a.id = c.article_id
            WHERE c.key IS NULL
               OR f.article_id IS NOT c.article_id
               OR f.title IS NOT a.title
               OR f.aliases IS NOT COALESCE((
                    SELECT group_concat(ordered_alias.alias, ' ')
                    FROM (
                        SELECT aa.alias
                        FROM help_article_alias aa
                        WHERE aa.article_id = a.id
                        ORDER BY aa.ordinal, aa.alias
                    ) ordered_alias
                  ), '')
               OR f.heading IS NOT c.heading
               OR f.body IS NOT c.body
            UNION ALL
            SELECT 1
            FROM help_claim c
            LEFT JOIN help_claim_fts f ON f.claim_key = c.key
            GROUP BY c.key
            HAVING count(f.rowid) != 1
            LIMIT 1
            """)
        defer { sqlite3_finalize(claimMismatch) }
        guard sqlite3_step(claimMismatch) == SQLITE_DONE else {
            throw MechanicianHelpError.malformed("claim FTS parity")
        }
    }

    private static func validateFTSSmokeQuery(_ database: OpaquePointer) throws {
        for table in ["help_claim_fts", "help_article_fts"] {
            let statement = try prepare(database, """
                SELECT rowid, bm25(\(table)) FROM \(table)('Mechanician') LIMIT 1
                """)
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 1) == SQLITE_FLOAT,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw MechanicianHelpError.malformed("FTS5 smoke query \(table)")
            }
        }
    }

    private static func matchExpression(
        for query: String,
        mode: MechanicianHelpQueryMode
    ) -> String? {
        let boundedQuery = String(
            decoding: query.utf8.prefix(maximumQueryUTF8Bytes),
            as: UTF8.self)
        let scalars = boundedQuery.unicodeScalars
        var tokens: [String] = []
        var current = ""
        var currentUTF8Bytes = 0
        for scalar in scalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                let scalarUTF8Bytes = scalar.utf8.count
                if currentUTF8Bytes + scalarUTF8Bytes <= maximumTokenUTF8Bytes {
                    current.unicodeScalars.append(scalar)
                    currentUTF8Bytes += scalarUTF8Bytes
                }
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
                currentUTF8Bytes = 0
            }
        }
        if !current.isEmpty { tokens.append(current) }
        var seen = Set<String>()
        tokens = tokens.filter { token in
            let normalized = token.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX"))
            guard normalized.count > 1 || normalized.allSatisfy(\.isNumber),
                  seen.insert(normalized).inserted else { return false }
            return true
        }
        if mode == .question {
            // Question framing, not content. "Show me the Changes panel" is the phrasing people
            // actually use, and leaving "show" and "me" in the expression made every such request
            // rank the article that describes the Show me feature above the panel being asked for.
            let stopWords: Set<String> = [
                "about", "and", "are", "can", "does", "for", "from", "how", "in", "into", "is",
                "me", "mechanician", "my", "of", "on", "show", "the", "this", "to", "what",
                "when", "where", "why", "with",
            ]
            let meaningful = tokens.filter { !stopWords.contains($0.lowercased()) }
            if !meaningful.isEmpty { tokens = meaningful }
        }
        tokens = Array(tokens.prefix(maximumQueryTokens))
        guard !tokens.isEmpty else { return nil }
        switch mode {
        case .typeahead:
            return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
                .joined(separator: " AND ")
        case .question:
            return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: " OR ")
        }
    }

    private static func utf8Size(
        of hit: MechanicianHelpSearchHit,
        noMoreThan limit: Int
    ) -> Int? {
        var remaining = limit
        var size = 0
        var values = [
            hit.claim.key, hit.claim.articleID, hit.claim.heading, hit.claim.body,
            hit.claim.kind.rawValue, hit.claim.lifecycle.rawValue,
            hit.article.id, hit.article.sectionID, hit.article.title, hit.article.icon,
            hit.article.blurb, hit.article.kind.rawValue, hit.article.lifecycle.rawValue,
        ]
        for evidence in hit.evidence {
            values.append(contentsOf: [
                evidence.id, evidence.kind.rawValue, evidence.path, evidence.anchor,
                evidence.sourceSHA256, evidence.anchorSHA256,
            ])
        }
        for value in values {
            let valueSize = value.utf8.prefix(remaining + 1).count
            guard valueSize <= remaining else { return nil }
            remaining -= valueSize
            size += valueSize
        }
        return size
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func prepare(
        _ database: OpaquePointer,
        _ sql: String
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            let detail = sqlite3_errmsg(database).map(String.init(cString:)) ?? "prepare failed"
            throw MechanicianHelpError.queryFailed(detail)
        }
        return statement
    }

    private static func text(
        _ statement: OpaquePointer,
        _ index: Int32,
        _ label: String
    ) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let raw = sqlite3_column_text(statement, index) else {
            throw MechanicianHelpError.malformed(label)
        }
        return String(cString: raw)
    }

    private static func integerPragma(_ database: OpaquePointer, _ name: String) -> Int32 {
        guard let statement = try? prepare(database, "PRAGMA \(name)") else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int(statement, 0)
    }

    private static func textPragma(_ database: OpaquePointer, _ name: String) -> String? {
        guard let statement = try? prepare(database, "PRAGMA \(name)") else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    private static func foreignKeyCheckIsEmpty(_ database: OpaquePointer) throws -> Bool {
        let statement = try prepare(database, "PRAGMA foreign_key_check")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private static func distinctValues(
        _ database: OpaquePointer,
        sql: String
    ) throws -> Set<String> {
        let statement = try prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        var values = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                values.insert(try text(statement, 0, "vocabulary value"))
            case SQLITE_DONE:
                return values
            default:
                throw MechanicianHelpError.queryFailed("vocabulary query")
            }
        }
    }

    private static func scalarCount(_ database: OpaquePointer, _ sql: String) throws -> Int64 {
        let statement = try prepare(database, sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MechanicianHelpError.queryFailed("count query")
        }
        return sqlite3_column_int64(statement, 0)
    }
}
