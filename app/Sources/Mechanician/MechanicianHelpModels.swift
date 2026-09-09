import Foundation

enum MechanicianHelpLifecycle: String, Codable, CaseIterable, Sendable {
    case current
    case historical
    case superseded
    case retired
}

enum MechanicianHelpClaimKind: String, Codable, CaseIterable, Sendable {
    case howTo
    case architecture
    case extensionPoint
    case troubleshooting
    case history
}

enum MechanicianHelpEvidenceKind: String, Codable, CaseIterable, Sendable {
    case source
    case test
    case architecture
    case canonicalDoc
    case release
    case history
}

struct MechanicianHelpBuildIdentity: Equatable, Sendable {
    let applicationVersion: String
    let applicationBuild: String
    let bundleIdentifier: String
    let tenantID: String?
    let sourceCommit: String?
    let sourceDiffSHA256: String?
    let helpCorpusSchemaVersion: Int?
    let helpCorpusSHA256: String?

    static func current(
        bundle: Bundle = .main,
        provenance: BuildProvenance? = BuildProvenance.current,
        tenantID: String? = nil
    ) -> MechanicianHelpBuildIdentity? {
        guard let applicationVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let applicationBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              let bundleIdentifier = bundle.bundleIdentifier else { return nil }
        let packagedTenantID = packagedTenantID(
            bundleIdentifier: bundleIdentifier,
            provenanceTenantID: provenance?.tenantId,
            override: tenantID)
        return MechanicianHelpBuildIdentity(
            applicationVersion: applicationVersion,
            applicationBuild: applicationBuild,
            bundleIdentifier: bundleIdentifier,
            tenantID: packagedTenantID,
            sourceCommit: provenance?.sourceCommit,
            sourceDiffSHA256: provenance?.sourceDiffSHA256,
            helpCorpusSchemaVersion: provenance?.helpCorpusSchemaVersion,
            helpCorpusSHA256: provenance?.helpCorpusSHA256)
    }

    static func packagedTenantID(
        bundleIdentifier: String,
        provenanceTenantID: String?,
        override: String? = nil
    ) -> String {
        if let override { return override }
        if let provenanceTenantID { return provenanceTenantID }
        // The development bundle has its own storage identity but deliberately packages the same
        // public Help authority. Custom legacy tenant bundles compile tenant-specific artifacts.
        if bundleIdentifier == MechanicianEnvironment.baseBundleIdentifier
            || bundleIdentifier == MechanicianEnvironment.devBundleIdentifier {
            return TenantProfile.defaultTenantId
        }
        return MechanicianEnvironment.identitySlug(for: bundleIdentifier)
            ?? TenantProfile.defaultTenantId
    }
}

struct MechanicianHelpMetadata: Equatable, Sendable {
    let schemaVersion: Int
    let corpusID: String
    let applicationVersion: String
    let applicationBuild: String
    let bundleIdentifier: String
    let tenantID: String
    let sourceCommit: String
    let sourceDiffSHA256: String
    let contentSHA256: String
}

struct MechanicianHelpEvidence: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let kind: MechanicianHelpEvidenceKind
    let path: String
    let anchor: String
    let sourceSHA256: String
    let anchorSHA256: String
}

struct MechanicianHelpArticleSummary: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let sectionID: String
    let title: String
    let icon: String
    let blurb: String
    let kind: MechanicianHelpClaimKind
    let lifecycle: MechanicianHelpLifecycle
    let ordinal: Int
}

struct MechanicianHelpSection: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let ordinal: Int
    let articles: [MechanicianHelpArticleSummary]
}

struct MechanicianHelpArticle: Identifiable, Equatable, Sendable {
    let summary: MechanicianHelpArticleSummary
    let markdown: String
    let evidence: [MechanicianHelpEvidence]
    let demonstrations: [MechanicianHelpDemonstration]
    let guides: [MechanicianHelpGuide]

    var id: String { summary.id }
}

/// The exact app-owned surface a signed guide may reveal. A guide names one of these semantic
/// destinations instead of carrying a workspace, conversation, window, route, or view identifier.
enum MechanicianHelpGuideSurface: String, Codable, CaseIterable, Sendable {
    case helpWorkspaceInspector
    case conversationWorkspace

    /// Help-local tours are started by their native reader control because their reveal actions
    /// depend on HelpBrowser state. Every other signed surface is an ordinary product surface the
    /// agent may present, so asking to be shown the Changes panel does not become a paragraph
    /// describing where the Changes panel is.
    var isAgentCallable: Bool {
        switch self {
        case .helpWorkspaceInspector: false
        case .conversationWorkspace: true
        }
    }
}

/// A stable app-owned element that Guided Help may spotlight. These values are semantic product
/// targets, not view selectors, accessibility identifiers, or coordinates.
enum MechanicianHelpGuideTarget: String, Codable, CaseIterable, Sendable {
    case helpInspectorTab
    case helpTopics
    case helpSearchField
    case helpArticleContent
    case helpArticleEvidence
    case helpDemonstrations
    case conversationFilesTab
    case conversationChangesTab
    case conversationArtifactsTab
    case conversationAgentsTab
    case conversationSkillsTab
    case conversationModelControl
    case conversationEffortControl
    case conversationPermissionControl
    case conversationComposer
}

/// A bounded native navigation operation. Article actions always resolve `guide.articleID`; no
/// guide can carry a caller-selected article, URL, script, selector, or coordinate payload.
enum MechanicianHelpGuideRevealAction: String, Codable, CaseIterable, Sendable {
    case none
    case showHelpInspector
    case showHelpTopics
    case showGuideArticle
    case showGuideEvidence
    case showGuideDemonstrations
    case showFilesInspector
    case showChangesInspector
    case showArtifactsInspector
    case showAgentsInspector
    case showSkillsInspector
    case showConversationControls
}

enum MechanicianHelpGuideCompletion: String, Codable, CaseIterable, Sendable {
    case targetVisible
    case targetActivated
    case textEntered
    case userAdvance
}

struct MechanicianHelpGuideStep: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let instruction: String
    let target: MechanicianHelpGuideTarget
    let revealAction: MechanicianHelpGuideRevealAction
    let completion: MechanicianHelpGuideCompletion
    let ordinal: Int
}

/// A signed native walkthrough. It can reveal and spotlight reviewed Mechanician surfaces, but it
/// grants no provider tool, automation permission, synthetic input, or external-app authority.
struct MechanicianHelpGuide: Identifiable, Equatable, Sendable {
    let id: String
    let articleID: String
    let title: String
    let summary: String
    let surface: MechanicianHelpGuideSurface
    let lifecycle: MechanicianHelpLifecycle
    let ordinal: Int
    let claimKeys: [String]
    let steps: [MechanicianHelpGuideStep]
    let evidence: [MechanicianHelpEvidence]
}

enum MechanicianHelpDemoRisk: String, Codable, CaseIterable, Sendable {
    case readOnly
    case sensitiveRead
    case reversibleLocal
    case additive
    case destructive
    case dynamic
}

enum MechanicianHelpDemoReversibilityKind: String, Codable, CaseIterable, Sendable {
    case notNeeded
    case automatic
    case manual
    case notGuaranteed
    case dynamic
}

struct MechanicianHelpDemoReversibility: Codable, Equatable, Sendable {
    let kind: MechanicianHelpDemoReversibilityKind
    let instructions: String
}

enum MechanicianHelpDemoConfirmation: String, Codable, CaseIterable, Sendable {
    case none
    case beforeDemo
    case beforeAct
}

enum MechanicianHelpDemoSession: String, Codable, CaseIterable, Sendable {
    case interactive
}

enum MechanicianHelpDemoMode: String, Codable, CaseIterable, Sendable {
    case readOnlyOkay
    case planCompatibleAction
    case executionEnabled
}

struct MechanicianHelpDemoRequirements: Codable, Equatable, Sendable {
    let session: MechanicianHelpDemoSession
    let mode: MechanicianHelpDemoMode
    let tools: [String]
}

enum MechanicianHelpDemoStepKind: String, Codable, CaseIterable, Sendable {
    case observe
    case ask
    case act
    case explain
}

struct MechanicianHelpDemoStep: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let kind: MechanicianHelpDemoStepKind
    let tool: String?
    let instruction: String
}

enum MechanicianHelpDemoVerificationKind: String, Codable, CaseIterable, Sendable {
    case toolSucceeded
    case visualState
    case userObserved
}

struct MechanicianHelpDemoVerification: Codable, Equatable, Sendable {
    let kind: MechanicianHelpDemoVerificationKind
    let stepID: String
    let instruction: String
}

enum MechanicianHelpDemoFallbackWhen: String, Codable, CaseIterable, Sendable {
    case toolUnavailable
    case emptyResult
    case permissionDenied
    case actionFailed
    case verificationFailed
}

enum MechanicianHelpDemoFallbackAction: String, Codable, CaseIterable, Sendable {
    case explain
    case useDemo
}

struct MechanicianHelpDemoFallback: Codable, Equatable, Sendable {
    let when: MechanicianHelpDemoFallbackWhen
    let action: MechanicianHelpDemoFallbackAction
    let demoID: String?
    let instruction: String
}

/// A reviewed demonstration plan. It is data for an agent to reason over, never an authorization
/// or an executable workflow: every named tool still has to be present on the exact live route and
/// pass that route's ordinary approval policy.
struct MechanicianHelpDemonstration: Identifiable, Equatable, Sendable {
    let id: String
    let articleID: String
    let title: String
    let outcome: String
    let lifecycle: MechanicianHelpLifecycle
    let ordinal: Int
    let claimKeys: [String]
    let requirements: MechanicianHelpDemoRequirements
    let risk: MechanicianHelpDemoRisk
    let reversibility: MechanicianHelpDemoReversibility
    let userConfirmation: MechanicianHelpDemoConfirmation
    let steps: [MechanicianHelpDemoStep]
    let verification: [MechanicianHelpDemoVerification]
    let fallback: [MechanicianHelpDemoFallback]
    let evidence: [MechanicianHelpEvidence]
}

struct MechanicianHelpDemoRecipe: Codable, Equatable, Sendable {
    let requirements: MechanicianHelpDemoRequirements
    let risk: MechanicianHelpDemoRisk
    let reversibility: MechanicianHelpDemoReversibility
    let userConfirmation: MechanicianHelpDemoConfirmation
    let steps: [MechanicianHelpDemoStep]
    let verification: [MechanicianHelpDemoVerification]
    let fallback: [MechanicianHelpDemoFallback]
}

struct MechanicianHelpClaim: Identifiable, Equatable, Sendable {
    let key: String
    let articleID: String
    let heading: String
    let body: String
    let kind: MechanicianHelpClaimKind
    let lifecycle: MechanicianHelpLifecycle
    let ordinal: Int

    var id: String { key }
}

enum MechanicianHelpQueryMode: Sendable {
    case typeahead
    case question
}

struct MechanicianHelpSearchRequest: Sendable {
    let text: String
    let mode: MechanicianHelpQueryMode
    let includeHistory: Bool
    let kinds: Set<MechanicianHelpClaimKind>
    let limit: Int

    init(
        text: String,
        mode: MechanicianHelpQueryMode = .question,
        includeHistory: Bool = false,
        kinds: Set<MechanicianHelpClaimKind> = [],
        limit: Int = 12
    ) {
        self.text = text
        self.mode = mode
        self.includeHistory = includeHistory
        self.kinds = kinds
        self.limit = limit
    }
}

struct MechanicianHelpSearchHit: Identifiable, Equatable, Sendable {
    let claim: MechanicianHelpClaim
    let article: MechanicianHelpArticleSummary
    let evidence: [MechanicianHelpEvidence]
    let score: Double

    var id: String { claim.key }
}

enum MechanicianHelpError: Error, Equatable, Sendable {
    case unavailable
    case cannotOpen
    case wrongApplicationID
    case unsupportedSchema(found: Int, expected: Int)
    case malformed(String)
    case buildMismatch(String)
    case queryFailed(String)
}
