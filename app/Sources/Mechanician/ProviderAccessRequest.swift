import Foundation

/// Durable app-owned work that is waiting for access to a provider family.
///
/// Agents may ask for Anthropic or OpenAI, but never choose a subscription or API credential.
/// The request owns its resume prompts until a user-selected access route is verified usable; only
/// then are they atomically transferred into the conversation's existing exact-once queue.
struct ProviderAccessRequest: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var maker: ModelMaker
    var reason: String
    var resumePrompts: [String]
    var requestedAt: Date = Date()
    var selectedAccess: ModelAccess? = nil
    /// Route whose terminal authentication failure owns `recoveryPromptEntryID`. This remains
    /// distinct from `selectedAccess`: reconnect-required lanes bind both to the failed route,
    /// while a non-disconnecting API failure still waits for the user to choose a usable route.
    var recoveryAccess: ModelAccess? = nil
    /// Exact user row already acknowledged for an app-authored authentication failure. When this
    /// request is fulfilled, that rejected row and its terminal failure are rewound before the
    /// prompt enters the runnable queue, so recovery creates one user row and sends one operative
    /// prompt instead of replaying the rejected prompt as both history and current input.
    var recoveryPromptEntryID: UUID? = nil

    /// Any one-sided persisted recovery identity is malformed and must remain fail-closed, so this
    /// intentionally reports true when either half is present. Fulfillment validates the pair.
    var hasAuthenticationRecovery: Bool {
        recoveryAccess != nil || recoveryPromptEntryID != nil
    }

    var providerName: String {
        switch maker {
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        }
    }

    var eligibleAccesses: [ModelAccess] {
        if hasAuthenticationRecovery {
            guard let recoveryAccess,
                  recoveryAccess.maker == maker else { return [] }
            if let selectedAccess {
                guard selectedAccess.maker == maker,
                      selectedAccess.isAllowedByEnterprisePolicy else { return [] }
                return [selectedAccess]
            }
        }
        return ModelAccess.selectableCases.filter { $0.maker == maker }
    }

    func accepts(_ access: ModelAccess) -> Bool {
        eligibleAccesses.contains(access)
    }

    /// Bind app-authored recovery work to the failed route only when that failure has actually
    /// disconnected its account. API authentication errors can leave a usable runtime/catalog;
    /// preselecting those would let generic ready processing immediately replay the failed prompt
    /// without a user choice and potentially loop.
    static func automaticRecoverySelection(
        for failure: ProviderFailure,
        failedAccess: ModelAccess
    ) -> ModelAccess? {
        guard failure.kind == .authentication,
              failure.requiresReconnect,
              failure.access == failedAccess else { return nil }
        return failedAccess
    }

    /// Explain why an ordinary queued prompt was promoted into preserved provider work. The exact
    /// Google recovery matters here: this card replaces the queue row and must not make a rejected
    /// saved sign-in look like a provider that is merely still starting.
    static func blockedQueueReason(
        for access: ModelAccess,
        requiresReconnect: Bool
    ) -> String {
        if access == .claudeVertex, requiresReconnect {
            return String(localized:
                "Reauthenticate with Google before Mechanician can send this preserved work through Google Vertex.")
        }
        return String(localized: "Continue work waiting for \(access.displayName).")
    }
}

extension Conversation {
    /// Stage one app-owned provider request. An authentication recovery prompt carries the exact
    /// transcript row it must rewind, so it cannot be folded into an earlier request whose model
    /// has no place to retain that identity. Failing closed leaves the existing request untouched
    /// and keeps the failed turn visible for an explicit retry after that request is resolved.
    @discardableResult
    mutating func stageProviderAccessRequest(
        maker: ModelMaker,
        reason: String,
        resumePrompts: [String],
        selectedAccess: ModelAccess?,
        recoveryAccess: ModelAccess?,
        recoveryPromptEntryID: UUID?
    ) -> UUID? {
        guard selectedAccess == nil || selectedAccess?.maker == maker,
              recoveryAccess == nil || recoveryAccess?.maker == maker,
              (recoveryAccess == nil) == (recoveryPromptEntryID == nil),
              !resumePrompts.isEmpty else { return nil }
        if var existing = providerAccessRequest {
            guard existing.maker == maker,
                  recoveryPromptEntryID == nil else { return nil }
            for prompt in resumePrompts where !existing.resumePrompts.contains(prompt) {
                existing.resumePrompts.append(prompt)
            }
            if existing.reason.isEmpty { existing.reason = reason }
            providerAccessRequest = existing
            return existing.id
        }
        let request = ProviderAccessRequest(
            maker: maker,
            reason: reason,
            resumePrompts: resumePrompts,
            selectedAccess: selectedAccess,
            recoveryAccess: recoveryAccess,
            recoveryPromptEntryID: recoveryPromptEntryID)
        providerAccessRequest = request
        return request.id
    }

    /// Move a settled, unusable lane's FIFO queue into the durable provider-access request that
    /// owns recovery. Clearing the queue and adopting every prompt happen in one authority
    /// mutation, so repeated ready/account callbacks cannot duplicate work. Equal strings remain
    /// distinct intentional queue items.
    @discardableResult
    mutating func preserveQueuedPromptsForProviderAccess(
        access: ModelAccess,
        requiresReconnect: Bool
    ) -> Bool {
        guard !queuedPrompts.isEmpty else { return false }
        let prompts = queuedPrompts
        if var existing = providerAccessRequest {
            guard existing.maker == access.maker else { return false }
            existing.resumePrompts.append(contentsOf: prompts)
            providerAccessRequest = existing
        } else {
            providerAccessRequest = ProviderAccessRequest(
                maker: access.maker,
                reason: ProviderAccessRequest.blockedQueueReason(
                    for: access,
                    requiresReconnect: requiresReconnect),
                resumePrompts: prompts,
                selectedAccess: access)
        }
        queuedPrompts.removeAll()
        return true
    }

    /// Persist a route choice without moving the task into the runnable queue. A later verified
    /// account/runtime callback owns fulfillment, so merely opening a browser can never send work.
    @discardableResult
    mutating func selectProviderAccess(_ access: ModelAccess, requestID: UUID) -> Bool {
        guard var request = providerAccessRequest,
              request.id == requestID,
              request.accepts(access) else { return false }
        request.selectedAccess = access
        providerAccessRequest = request
        return true
    }

    /// Fulfill once. Clearing the request and appending its prompts happen in one conversation-store
    /// mutation; a duplicate login/ready callback sees no matching request and becomes a no-op.
    @discardableResult
    mutating func fulfillProviderAccess(
        requestID: UUID,
        access: ModelAccess,
        modelID: String
    ) -> Bool {
        guard let request = providerAccessRequest,
              request.id == requestID,
              request.selectedAccess == access,
              request.accepts(access),
              !modelID.isEmpty else { return false }
        let rewoundMessages: [TranscriptEntry]?
        let resumedPrompts: [String]
        if request.hasAuthenticationRecovery {
            guard let recoveryPromptEntryID = request.recoveryPromptEntryID,
                  let recoveryAccess = request.recoveryAccess,
                  let rewind = authenticationRecoveryRewind(
                      promptEntryID: recoveryPromptEntryID,
                      prompts: request.resumePrompts,
                      failedAccess: recoveryAccess) else { return false }
            rewoundMessages = rewind
            // Prompts queued behind the failed root are newer work. Keep the rejected root first,
            // then preserve every queued item (including intentional equal strings) in FIFO order.
            resumedPrompts = request.resumePrompts + queuedPrompts
        } else {
            guard queuedPrompts.isEmpty else { return false }
            rewoundMessages = nil
            resumedPrompts = request.resumePrompts
        }
        let previousAccess = modelSelection?.access
        AgentBridge.advanceProviderHistoryReplayBoundary(
            on: &self,
            from: previousAccess,
            to: access)
        if let rewoundMessages { messages = rewoundMessages }
        providerAccessRequest = nil
        AgentBridge.retireProviderSession(on: &self)
        modelSelection = ModelSelection(access: access, modelID: modelID)
        queuedPrompts = resumedPrompts
        errored = false
        return true
    }

    /// Authentication preflight rejected this exact turn before provider output or tool work. The
    /// transcript failure remains visible while sign-in is required, then fulfillment atomically
    /// replaces the failed user/failure pair with the runnable prompt. Any unexpected transcript
    /// shape fails closed instead of risking a duplicate provider submission.
    private func authenticationRecoveryRewind(
        promptEntryID: UUID,
        prompts: [String],
        failedAccess: ModelAccess
    ) -> [TranscriptEntry]? {
        guard let promptIndex = messages.firstIndex(where: {
                      $0.id == promptEntryID && $0.kind == .user
              }),
              prompts.contains(messages[promptIndex].text),
              let failureIndex = messages.indices.last(where: { index in
                  let entry = messages[index]
                  return entry.kind == .system
                      && entry.providerFailure?.kind == .authentication
                      && entry.providerFailure?.access == failedAccess
                      && entry.providerFailurePromptID == promptEntryID
              }),
              promptIndex < failureIndex,
              failureIndex == messages.index(before: messages.endIndex),
              messages[(promptIndex + 1)..<failureIndex].allSatisfy({ entry in
                  if entry.kind == .compaction { return true }
                  guard entry.kind == .system else { return false }
                  return entry.providerFailure == nil
                      && entry.refusal == nil
                      && entry.usageLimit == nil
              }) else { return nil }
        return Array(messages[..<promptIndex])
    }

    /// Cancel only the named provider request. Transcript, model/session, other queued work, and
    /// account state are deliberately outside this reducer.
    @discardableResult
    mutating func cancelProviderAccess(requestID: UUID) -> Bool {
        guard providerAccessRequest?.id == requestID else { return false }
        providerAccessRequest = nil
        return true
    }
}
