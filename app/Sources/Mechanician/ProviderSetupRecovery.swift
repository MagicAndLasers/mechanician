import Foundation

/// A narrowly scoped hand-off from the composer's provider-setup banner to the Providers window.
///
/// Opening Providers by itself carries no routing authority. The banner first records the exact
/// conversation and selection it is trying to recover; a concrete account action then binds that
/// intent to one destination. Resolution remains gated on both verified account success and a
/// current, authoritative model catalog, so cached rows can never retarget a conversation.
struct ProviderSetupRecovery: Equatable {
    /// Provider startup and account mutation are separate asynchronous edges. In particular, a
    /// runtime can be fully ready yet definitively reject a saved credential. Treating that state as
    /// generic "waiting" leaves the recovery card spinning forever because no later ready event is
    /// coming to change it.
    enum RuntimeEvidence: Equatable {
        case waiting
        case verified
        case rejected
    }

    struct Intent: Equatable {
        let originConversationID: UUID
        let originalSelection: ModelSelection
        fileprivate(set) var destination: ModelAccess?
        fileprivate(set) var verifiedCredentialEpoch: Int?
    }

    /// The small conversation projection needed to decide whether an automatic route change is
    /// still the action the user requested. Draft text and idle history/session state are
    /// deliberately represented but are not blockers: this explicit recovery flow replaces the
    /// hidden model-picker step and must preserve both the draft and established conversation.
    struct ConversationState: Equatable {
        var conversationID: UUID?
        var selection: ModelSelection?
        var hasDraft: Bool
        var hasSession: Bool
        var hasUserOrAssistantTranscript: Bool
        var queuedPromptCount: Int
        var delegatedWorkCount: Int
        var hasProviderAccessRequest: Bool
        var hasReservedTurn: Bool
        var hasArmedWait: Bool

        fileprivate var isEligible: Bool {
            queuedPromptCount == 0
                && delegatedWorkCount == 0
                && !hasProviderAccessRequest
                && !hasReservedTurn
                && !hasArmedWait
        }
    }

    /// Catalog evidence is accepted only when it belongs to the destination's current credential
    /// epoch and is provider-authoritative (`ready`). Last-known/loading/failed rows are useful UI
    /// evidence, but never authority for an automatic model choice.
    struct CatalogEvidence: Equatable {
        var access: ModelAccess
        var snapshot: ModelCatalogSnapshot
        var currentCredentialEpoch: Int
    }

    private(set) var intent: Intent?

    var isPending: Bool { intent != nil }

    static func runtimeEvidence(
        accountOperationInFlight: Bool,
        runtimeIsReady: Bool,
        runtimeIsUsable: Bool
    ) -> RuntimeEvidence {
        if accountOperationInFlight || !runtimeIsReady { return .waiting }
        return runtimeIsUsable ? .verified : .rejected
    }

    /// Start (or replace) the one pending recovery with the exact route visible behind the banner.
    mutating func begin(
        originConversationID: UUID,
        originalSelection: ModelSelection
    ) {
        intent = Intent(
            originConversationID: originConversationID,
            originalSelection: originalSelection,
            destination: nil,
            verifiedCredentialEpoch: nil)
    }

    /// Bind the banner-originated intent to the account action the user chose in Providers.
    /// Returning false lets a generic Providers action remain routing-neutral when no intent exists.
    @discardableResult
    mutating func bind(destination: ModelAccess) -> Bool {
        guard var intent else { return false }
        intent.destination = destination
        intent.verifiedCredentialEpoch = nil
        self.intent = intent
        return true
    }

    /// Record only a verified completion for the bound destination. The epoch becomes part of the
    /// proof so a later credential mutation cannot reuse this success with a different account.
    @discardableResult
    mutating func markVerifiedSuccess(
        for access: ModelAccess,
        credentialEpoch: Int
    ) -> Bool {
        guard var intent, intent.destination == access else { return false }
        intent.verifiedCredentialEpoch = credentialEpoch
        self.intent = intent
        return true
    }

    /// Return the provider default that AgentBridge may pass to its existing `selectModel` path.
    ///
    /// Ineligible or manually changed origins consume the intent: the original user action no
    /// longer applies. Incomplete asynchronous evidence leaves it pending so account completion and
    /// catalog publication may arrive in either order. A successful result is one-shot.
    mutating func resolveIfReady(
        current: ConversationState,
        catalog: CatalogEvidence?
    ) -> ModelSelection? {
        guard let intent else { return nil }
        guard originIsStillEligible(intent, current: current) else {
            self.intent = nil
            return nil
        }
        guard let destination = intent.destination,
              let verifiedEpoch = intent.verifiedCredentialEpoch,
              let catalog,
              catalog.access == destination,
              catalog.currentCredentialEpoch == verifiedEpoch,
              catalog.snapshot.credentialEpoch == verifiedEpoch,
              catalog.snapshot.phase == .ready else {
            return nil
        }
        let entries = catalog.snapshot.entries.filter {
            $0.selection.access == destination && !$0.selection.modelID.isEmpty
        }
        guard let selected = entries.first(where: \.isDefault) ?? entries.first else {
            return nil
        }
        self.intent = nil
        return selected.selection
    }

    /// A recovered credential on the original route needs no model change and therefore no catalog
    /// edge. Runtime usability is the authoritative proof; clearing this transient intent leaves
    /// the conversation's existing model and opaque-session recovery policy untouched.
    mutating func completeOriginalRouteIfReady(
        current: ConversationState,
        usableAccess: ModelAccess,
        currentCredentialEpoch: Int
    ) -> Bool {
        guard let intent else { return false }
        guard originIsStillEligible(intent, current: current) else {
            self.intent = nil
            return false
        }
        guard intent.destination == intent.originalSelection.access,
              usableAccess == intent.originalSelection.access,
              intent.verifiedCredentialEpoch == currentCredentialEpoch else {
            return false
        }
        self.intent = nil
        return true
    }

    mutating func cancel() {
        intent = nil
    }

    private func originIsStillEligible(
        _ intent: Intent,
        current: ConversationState
    ) -> Bool {
        current.conversationID == intent.originConversationID
            && current.selection == intent.originalSelection
            && current.isEligible
    }
}
