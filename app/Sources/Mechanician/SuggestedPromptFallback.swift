import Foundation

/// Role-preserving evidence used to validate a generated action handoff. User text prevents an old
/// goal from resurfacing, while the final Assistant message is the sole authority for what action
/// may be suggested next.
struct SuggestedPromptCandidateGrounding: Equatable, Sendable {
    let currentTurnUserPrompts: [String]
    let assistantHandoff: String

    var allPrompts: [String] {
        currentTurnUserPrompts + [assistantHandoff]
    }
}

/// The bounded dialogue handed to Apple Intelligence for an action handoff. Recalled memory is
/// intentionally excluded: if it affected the answer and remains relevant, the final Assistant
/// message will say so. A memory card must never independently originate the next action.
struct SuggestedPromptFallbackSnapshot: Equatable, Sendable {
    let context: String
    let latestUserPrompt: String
    /// Genuine User rows that belong to the turn being continued. These ground relevance without
    /// letting an unrelated earlier goal authorize a stale suggestion. Keep the whole turn rather
    /// than only `latestUserPrompt`: terse steering such as "yes, please" must not erase the root
    /// request that gives it meaning.
    let currentTurnUserPrompts: [String]
    /// Every genuine User prompt through this completed exchange, retained locally for rejection
    /// only. Older prompts are deliberately absent from `context`, so the model cannot copy them,
    /// but a provider or local candidate that reproduces one can still be caught before display.
    let userPromptsToAvoid: [String]
    /// The final Assistant message. Deterministic compilation and model validation read only this
    /// field, never earlier Assistant progress, quoted memory, or recalled memory cards.
    let assistantHandoff: String
    let sourceEntryIDs: [UUID]
    let assistantEntryID: UUID
    let resumedFromWaitMode: Bool

    var candidateGrounding: SuggestedPromptCandidateGrounding {
        SuggestedPromptCandidateGrounding(
            currentTurnUserPrompts: currentTurnUserPrompts,
            assistantHandoff: assistantHandoff)
    }
}

struct SuggestedPromptFallbackAttempt: Equatable, Sendable {
    let conversationID: UUID
    let turnID: String
    let generation: UInt64
    let snapshot: SuggestedPromptFallbackSnapshot
    /// The exact prior value this attempt is allowed to replace. A provider suggestion or any
    /// other mutation that lands while the local model runs wins by changing this value.
    let observedSuggestedPrompt: ConversationSuggestedPrompt?
}

enum SuggestedPromptCandidateRejection: String, Equatable, Hashable, Sendable {
    case noCandidates = "no_candidates"
    case multipleLines = "multiple_lines"
    case assistantVoice = "assistant_voice"
    case invalidLength = "invalid_length"
    case repeatedPrompt = "repeated_prompt"
    case ephemeralReference = "ephemeral_reference"
    case statusInstruction = "status_instruction"
    case invalidStyle = "invalid_style"
    case notPrescribed = "not_prescribed"
    case ungrounded = "ungrounded"
    case sentinel = "sentinel"
    case generationFailed = "generation_failed"
    case mixed = "mixed"
}

struct SuggestedPromptCandidateSelection: Equatable, Sendable {
    let suggestion: String?
    let candidateCount: Int
    let rejection: SuggestedPromptCandidateRejection?
}

enum SuggestedPromptFallback {
    private enum PromptActionCategory: Hashable {
        case implementation
        case verification
        case investigation
        case delivery
        case documentation
        case continuation
        case discussion
    }

    static let maximumContextCharacters = 4_000
    static let maximumSuggestionCharacters = 120
    static let maximumSuggestionWords = 12
    private static let maximumConversationCharacters = 3_300
    private static let maximumRootGoalCharacters = 1_100
    private static let maximumSteeringCharacters = 1_000
    private static let maximumAssistantHandoffCharacters = 1_100
    private static let promptActionWords: Set<String> = [
        "accept", "add", "apply", "audit", "build", "cancel", "capture", "check",
        "choose", "commit", "compare", "complete", "configure", "confirm", "connect",
        "continue", "convert", "create", "delete", "deploy", "design", "diagnose",
        "disable", "discuss", "document", "draft", "enable", "explain", "expand", "expose",
        "extract", "finalize", "finish", "fix", "generate", "guard", "harden", "implement",
        "improve", "inspect", "install", "integrate", "investigate", "make", "measure",
        "merge", "migrate", "move", "open", "outline", "persist", "prepare", "prioritize",
        "proceed", "profile", "project", "promote", "propose", "publish", "push", "read",
        "rebuild", "record", "refactor", "refine", "relaunch", "release", "remove", "rename",
        "replace", "replay", "restore", "retry", "rerun", "revert", "review", "run", "set",
        "ship", "show", "simplify", "start", "stop", "strengthen", "suggest", "summarize",
        "switch", "tell", "test", "trace", "update", "use", "validate", "verify", "wire",
        "write",
    ]

    /// A focused test pins this closed grammar to the action-category policy used by restatement
    /// detection. Adding a verb without classifying it would otherwise make valid handoffs vanish.
    static var uncategorizedPromptActionWords: Set<String> {
        Set(promptActionWords.filter { promptActionCategory($0) == nil })
    }

    /// Codex has no provider-authored prompt-suggestion surface, so a successful ordinary Codex
    /// turn may use the local action extractor after streaming ends. Claude owns its suggestions;
    /// an absent or provider-suppressed Claude suggestion is not permission to synthesize one.
    /// Local-model availability is not an eligibility gate: the deterministic compiler runs first,
    /// and the model path reports unavailable when needed.
    static func mayGenerate(
        access: ModelAccess,
        isConversationTurn: Bool,
        wasInterrupted: Bool,
        isConversationAvailable: Bool,
        isWorking: Bool,
        isStreaming: Bool,
        hasNativeSuggestion: Bool,
        modelIsAvailable _: Bool
    ) -> Bool {
        access == .codexSubscription
            && isConversationTurn
            && !wasInterrupted
            && isConversationAvailable
            && !isWorking
            && !isStreaming
            && !hasNativeSuggestion
    }

    /// The post-await half of the contract. In particular, generation equality distinguishes a
    /// genuinely empty suggestion slot from one where a provider suggestion arrived and the user
    /// already accepted it while the local model was still responding.
    static func mayPublish(
        _ attempt: SuggestedPromptFallbackAttempt,
        targetConversationID: UUID?,
        currentGeneration: UInt64,
        currentSnapshot: SuggestedPromptFallbackSnapshot?,
        isWorking: Bool,
        isStreaming: Bool,
        currentSuggestedPrompt: ConversationSuggestedPrompt?
    ) -> Bool {
        attempt.conversationID == targetConversationID
            && attempt.generation == currentGeneration
            && attempt.snapshot == currentSnapshot
            && !isWorking
            && !isStreaming
            && currentSuggestedPrompt == attempt.observedSuggestedPrompt
    }

    /// Bounded current-turn dialogue with illustrative/code blocks removed. No recalled memory, tool
    /// payloads, system envelopes, provider instructions, or file contents are included.
    static func snapshot(
        from entries: [TranscriptEntry],
        turnID _: String,
        rootPromptEntryID: UUID?
    ) -> SuggestedPromptFallbackSnapshot? {
        guard let rootPromptEntryID,
              let rootPromptIndex = entries.firstIndex(where: {
                  $0.id == rootPromptEntryID && $0.kind == .user
              }) else {
            return nil
        }
        let resumedFromWaitMode = isSyntheticResumePrompt(entries[rootPromptIndex].text)
        let rootGoal: TranscriptEntry
        if resumedFromWaitMode {
            guard let goalIndex = entries.indices[..<rootPromptIndex].last(where: {
                isGenuineUser(entries[$0])
            }) else { return nil }
            rootGoal = entries[goalIndex]
        } else {
            guard isGenuineUser(entries[rootPromptIndex]) else { return nil }
            rootGoal = entries[rootPromptIndex]
        }

        // The action bar continues the final Assistant message, not the accumulated progress log.
        // Keep the request and genuine steering for relevance and echo rejection, but make the last
        // visible Assistant row the sole source of a proposed next action.
        guard let finalDialogueIndex = entries.indices.last(where: {
            let entry = entries[$0]
            return isGenuineUser(entry)
                || (entry.kind == .assistant && !trimmed(entry.text).isEmpty)
        }),
              finalDialogueIndex > rootPromptIndex,
              entries[finalDialogueIndex].kind == .assistant else { return nil }
        let finalAssistant = entries[finalDialogueIndex]
        let steeringIndices = entries.indices[
            entries.index(after: rootPromptIndex)..<finalDialogueIndex
        ].filter { isGenuineUser(entries[$0]) }
        let steering = steeringIndices.map { entries[$0] }
        let latestUser = steering.last ?? rootGoal
        let assistantHandoff = bounded(
            assistantActionSource(from: finalAssistant.text),
            to: maximumAssistantHandoffCharacters)

        let currentTurnUserEntries = [rootGoal] + steering
        let userPromptsToAvoid = entries[...finalDialogueIndex]
            .filter(isGenuineUser)
            .map(\.text)

        var sourceEntryIDs = [rootGoal.id]
        sourceEntryIDs.append(contentsOf: steering.map(\.id))
        sourceEntryIDs.append(finalAssistant.id)

        var dialogueBlocks: [String] = []
        dialogueBlocks.append(
            "User:\n\(bounded(rootGoal.text, to: maximumRootGoalCharacters))")
        if !steering.isEmpty {
            let steeringText = steering.map { trimmed($0.text) }.joined(separator: "\n\n")
            dialogueBlocks.append(
                "User (steering during this turn):\n"
                    + bounded(steeringText, to: maximumSteeringCharacters))
        }
        dialogueBlocks.append(
            "Assistant (final message):\n" + assistantHandoff)
        let boundedDialogue = bounded(
            dialogueBlocks.joined(separator: "\n\n"),
            to: maximumConversationCharacters)
        let context = bounded(boundedDialogue, to: maximumContextCharacters)
        guard !context.isEmpty else { return nil }
        return SuggestedPromptFallbackSnapshot(
            context: context,
            latestUserPrompt: latestUser.text.trimmingCharacters(in: .whitespacesAndNewlines),
            currentTurnUserPrompts: currentTurnUserEntries.map(\.text),
            userPromptsToAvoid: userPromptsToAvoid,
            assistantHandoff: assistantHandoff,
            sourceEntryIDs: sourceEntryIDs,
            assistantEntryID: finalAssistant.id,
            resumedFromWaitMode: resumedFromWaitMode)
    }

    /// Compile an explicit handoff before asking a language model to restate one.
    ///
    /// The compiler deliberately has a small, closed grammar. It accepts only a named next action
    /// or recommendation, an explicit offer, or the first list item under an ordered-next heading.
    /// Descriptive text, examples, capability statements, bare imperatives, and instructions for
    /// the person compile to nothing rather than being promoted into assistant work.
    ///
    /// It parses only the final Assistant message, then grounds the extracted action against genuine
    /// User messages. The one grounding exception is an explicit prescription after generic
    /// "what next?" steering, where the user deliberately delegated the concrete target. Earlier
    /// complaints and memory cards can never become output.
    static func compiledHandoff(
        from snapshot: SuggestedPromptFallbackSnapshot
    ) -> String? {
        guard let raw = compileAssistantHandoff(
            snapshot.assistantHandoff,
            // Ground only in genuine User prompts from this turn. Older goals are retained solely
            // in the local rejection corpus, so work from another turn cannot authorize a stale
            // suggestion while terse steering still keeps the root request meaningful.
            groundedBy: snapshot.currentTurnUserPrompts
        ) else { return nil }
        return sanitized(
            raw,
            avoiding: snapshot.latestUserPrompt,
            userPromptsToAvoid: snapshot.userPromptsToAvoid,
            grounding: snapshot.candidateGrounding)
    }

    private struct HandoffUnit {
        let text: String
        let listOrdinal: Int?
        let isListItem: Bool
    }

    private static func compileAssistantHandoff(
        _ response: String,
        groundedBy userPrompts: [String]
    ) -> String? {
        let units = handoffUnits(response)

        // Only an explicit forward prescription is eligible. A bare imperative, capability claim,
        // example, or instruction for the person is not an assistant offer and cannot become one.
        for index in units.indices.reversed() {
            let text = units[index].text
            // An unanswered A/B question does not establish which branch the user wants. Let the
            // model decline instead of putting another question or an invented preference in the
            // suggestion bar.
            if isChoiceQuestion(text) { return nil }
            if isUserSideOperationRequest(text) { return nil }
            guard let action = explicitPrescriptionAction(at: index, in: units) else { continue }
            guard !containsEphemeralBuildReference(text),
                  !containsMultipleActions(action),
                  let command = renderedCommand(action, permitsOperationalCommand: true),
                  isExplicitHandoffGrounded(command, by: userPrompts) else { return nil }
            return command
        }
        return nil
    }

    private static func explicitPrescriptionAction(
        at index: Int,
        in units: [HandoffUnit]
    ) -> String? {
        offeredAction(in: units[index].text)
            ?? namedAction(in: units[index].text)
            ?? (isFirstItemUnderOrderedHandoff(at: index, in: units)
                ? units[index].text : nil)
    }

    private static func offeredAction(in value: String) -> String? {
        firstCapture(
            #"(?i)^(?:should|shall|can|could|may)\s+(?:i|we)\s+(.+?)\?$"#,
            in: value
        ) ?? firstCapture(
            #"(?i)^(?:would\s+you\s+like|do\s+you\s+want)\s+(?:me|us)\s+to\s+(.+?)\?$"#,
            in: value
        ) ?? firstCapture(
            #"(?i)^if\s+(?:you(?:['’]d|\s+would)\s+like|you\s+want|that\s+helps),\s+(?:i|we)\s+can\s+(.+?)[.!]?$"#,
            in: value
        ) ?? firstCapture(
            #"(?i)^(?:i|we)\s+can\s+(.+?)\s+if\s+(?:you(?:['’]d|\s+would)\s+like|you\s+want|that\s+helps)[.!]?$"#,
            in: value
        ) ?? firstCapture(
            #"(?i)^(?:please\s+)?let\s+me\s+know\s+if\s+you(?:['’]d|\s+would)\s+like\s+(?:me|us)\s+to\s+(.+?)[.!]?$"#,
            in: value)
    }

    private static func namedAction(in value: String) -> String? {
        firstCapture(
            #"(?i)^(?:next|next\s+(?:action|step))\s*[:,\-]\s*(.+)$"#,
            in: value
        ) ?? firstCapture(
            #"(?i)^(?:i|we)(?:['’]d|\s+would)\s+(make\s+(?:this|that)\s+(?:the|our)\s+next(?:\s+[a-z0-9-]+){0,3}\s+(?:action|step|task|slice))[.!]?$"#,
            in: value
        ) ?? firstCapture(
            #"(?i)^the\s+next(?:\s+[a-z0-9-]+){0,3}\s+(?:action|step|task|slice)\s+(?:is|will\s+be|should\s+be|would\s+be)\s+(?:to\s+)?(.+)$"#,
            in: value
        ) ?? firstCapture(
            #"(?i)^(?:instead\s*[,:\-]\s*)?(?:i(?:['’]d|\s+would)?\s+(?:recommend|suggest)|my\s+recommendation\s+is|recommendation\s*:)\s+(?:that\s+)?(?:(?:we|you)\s+)?(?:should\s+|to\s+)?(.+)$"#,
            in: value
        ) ?? firstCapture(
            #"(?i)^(?:(?:a|the)\s+)?(?:good|best|better|cleanest|clearest|safe|safest|simple|simplest|most\s+useful|recommended)\s+(?:approach|pattern|fix|option|choice|next\s+step|next\s+action)(?:\s+for\s+.+?)?\s+is\s+(?:to\s+)?(.+)$"#,
            in: value
        ) ?? firstCapture(
            #"(?i)^(?:a\s+useful\s+next\s+step|the\s+remaining\s+action)\s+is\s+(?:to\s+)?(.+)$"#,
            in: value
        ) ?? firstCapture(
            #"(?i)^my\s+proposed\s+next\s+(?:step|action)\s+is\s+(?:to\s+)?(.+)$"#,
            in: value
        ) ?? firstCapture(
            #"(?i)^(?:my|our)\s+(?:proposed\s+)?next\s+(?:step|action)\s+(?:is|will\s+be)\s+(?:to\s+)?(.+)$"#,
            in: value
        ) ?? firstCapture(
            #"(?i)^we\s+should\s+(.+)$"#,
            in: value)
    }

    private static func isFirstItemUnderOrderedHandoff(
        at index: Int,
        in units: [HandoffUnit]
    ) -> Bool {
        guard units[index].isListItem,
              units[index].listOrdinal == nil || units[index].listOrdinal == 1 else { return false }
        guard index > units.startIndex else { return false }
        let anchorIndex = units.index(before: index)
        return isOrderedHandoffAnchor(units[anchorIndex].text)
    }

    private static func isChoiceQuestion(_ value: String) -> Bool {
        let folded = normalizedVoice(value)
        guard value.hasSuffix("?"), folded.contains(" or ") else { return false }
        return [
            "which ", "would you prefer ", "do you prefer ", "should i ", "should we ",
            "would you like me to ", "do you want me to ",
        ].contains(where: folded.hasPrefix)
    }

    private static func isUserSideOperationRequest(_ value: String) -> Bool {
        firstCapture(
            #"(?i)^(?:after\s+this\s+response|once\s+[^,]+|when\s+[^,]+)\s*[:,]\s*((?:show|verify|validate|test|check|inspect|install)\b.+)$"#,
            in: value) != nil
            || firstCapture(
                #"(?i)^(?:please\s+)?((?:show|verify|validate|test|check|inspect|install)\b.+)$"#,
                in: value) != nil
            || firstCapture(
                #"(?i)^(?:can|could|will|would)\s+you\s+(?:please\s+)?((?:show|verify|validate|test|check|inspect|install)\b.+?)\?$"#,
                in: value) != nil
    }

    private static func isOrderedHandoffAnchor(_ value: String) -> Bool {
        let folded = normalizedVoice(value)
        let core = folded.hasSuffix(":") ? String(folded.dropLast()) : folded
        if [
            "actual next step", "actual next steps", "correct order", "next steps",
            "proposed next step", "proposed next steps", "recommended next step",
            "recommended next steps", "recommended order",
        ].contains(core) {
            return true
        }
        guard folded.hasSuffix(":") else { return false }
        return folded.hasPrefix("correct order")
            || folded.hasPrefix("recommended order")
            || folded.hasPrefix("next steps")
            || (folded.hasPrefix("the next ")
                && (folded.contains(" sequence ") || folded.contains(" order ")))
    }

    private static func renderedCommand(
        _ raw: String,
        permitsOperationalCommand: Bool = false,
        enforcesCharacterLimit: Bool = true
    ) -> String? {
        var action = strippedTerminalPunctuation(trimmed(raw))
        action = replacingFirstMatch(
            #"(?i)^(?:that\s+)?(?:(?:i|we|you)\s+(?:will|should|can|could|need\s+to|must)\s+|to\s+)"#,
            in: action,
            with: "")
        action = strippedTerminalPunctuation(trimmed(action))
        guard !action.isEmpty,
              !containsEphemeralBuildReference(action),
              !containsMultipleActions(action),
              !isPronounOnlyAction(action) else { return nil }

        let gerunds: [(String, String)] = [
            ("implementing", "Implement"), ("fixing", "Fix"), ("adding", "Add"),
            ("removing", "Remove"), ("wiring", "Wire"), ("building", "Build"),
            ("running", "Run"), ("testing", "Test"), ("verifying", "Verify"),
            ("validating", "Validate"), ("inspecting", "Inspect"),
            ("diagnosing", "Diagnose"), ("continuing", "Continue"),
            ("documenting", "Document"), ("recording", "Record"),
            ("creating", "Create"), ("updating", "Update"),
            ("comparing", "Compare"), ("replaying", "Replay"),
            ("reviewing", "Review"), ("promoting", "Promote"),
            ("accepting", "Accept"), ("installing", "Install"),
            ("discussing", "Discuss"), ("designing", "Design"),
            ("auditing", "Audit"), ("investigating", "Investigate"),
            ("refactoring", "Refactor"), ("retrying", "Retry"),
            ("renaming", "Rename"), ("shipping", "Ship"),
            ("hardening", "Harden"), ("simplifying", "Simplify"),
            ("migrating", "Migrate"), ("profiling", "Profile"),
            ("applying", "Apply"), ("choosing", "Choose"),
            ("committing", "Commit"), ("configuring", "Configure"),
            ("connecting", "Connect"), ("converting", "Convert"),
            ("deploying", "Deploy"), ("disabling", "Disable"),
            ("drafting", "Draft"), ("explaining", "Explain"),
            ("exposing", "Expose"), ("extracting", "Extract"),
            ("finalizing", "Finalize"), ("finishing", "Finish"),
            ("generating", "Generate"), ("integrating", "Integrate"),
            ("measuring", "Measure"), ("outlining", "Outline"),
            ("preparing", "Prepare"), ("prioritizing", "Prioritize"),
            ("proceeding", "Proceed"), ("proposing", "Propose"),
            ("publishing", "Publish"), ("refining", "Refine"),
            ("releasing", "Release"), ("replacing", "Replace"),
            ("restoring", "Restore"), ("showing", "Show"),
            ("summarizing", "Summarize"), ("telling", "Tell"),
            ("tracing", "Trace"), ("using", "Use"), ("writing", "Write"),
            ("cancelling", "Cancel"), ("canceling", "Cancel"),
            ("deleting", "Delete"), ("guarding", "Guard"),
            ("merging", "Merge"), ("moving", "Move"), ("opening", "Open"),
            ("persisting", "Persist"), ("pushing", "Push"),
            ("rebuilding", "Rebuild"), ("relaunching", "Relaunch"),
            ("rerunning", "Rerun"), ("reverting", "Revert"),
            ("setting", "Set"), ("starting", "Start"), ("stopping", "Stop"),
            ("switching", "Switch"), ("reading", "Read"),
        ]
        let folded = normalizedVoice(action)
        for (gerund, imperative) in gerunds {
            if folded == gerund || folded.hasPrefix(gerund + " ") {
                action = imperative + action.dropFirst(gerund.count)
                break
            }
        }

        let imperative = normalizedVoice(action).split(separator: " ").first.map(String.init) ?? ""
        let userSideOperations: Set<String> = [
            "test", "verify", "validate", "check", "confirm", "inspect", "install",
        ]
        guard promptActionWords.contains(imperative),
              permitsOperationalCommand || !userSideOperations.contains(imperative) else {
            return nil
        }
        action = action.prefix(1).uppercased() + String(action.dropFirst())
        let command = action + "."
        guard !enforcesCharacterLimit
                || command.count <= maximumSuggestionCharacters else { return nil }
        return command
    }

    private static func isGrounded(_ candidate: String, by userPrompts: [String]) -> Bool {
        let candidateKey = comparisonKey(candidate)
        let candidateAction = candidateKey.split(separator: " ").first
            .map { stem(String($0)) }
            .flatMap { promptActionWords.contains($0) ? $0 : nil }
        let candidateTokens = contentTokens(candidate).subtracting(promptActionWords)
        guard !candidateTokens.isEmpty else { return false }
        return userPrompts.contains { prompt in
            let promptKey = comparisonKey(prompt)
            if candidateKey.count >= 12, promptKey.contains(candidateKey) { return true }
            let promptTokens = contentTokens(prompt).subtracting(promptActionWords)
            let overlap = candidateTokens.intersection(promptTokens)
            if overlap.count >= 2 { return true }
            return overlap.contains(where: { $0.count >= 6 })
                && candidateAction.map { contentTokens(prompt).contains($0) } == true
        }
    }

    /// A terse request for the assistant's next step deliberately delegates the concrete target to
    /// the final response. That one shape may rely on the explicit prescription itself for subject
    /// grounding; arbitrary terse steering such as "yes" still needs the root goal's vocabulary.
    private static func isExplicitHandoffGrounded(
        _ candidate: String,
        by userPrompts: [String]
    ) -> Bool {
        isGrounded(candidate, by: userPrompts)
            || userPrompts.last.map(isGenericNextStepPrompt) == true
            || isDeicticNextActionGrounded(candidate, by: userPrompts)
    }

    /// A final response may adopt the user's just-discussed proposal without repeating its complete
    /// noun phrase: "I'd make this the next Help slice." Keep that natural handoff useful, but do
    /// not turn a bare "make this next" or an unrelated older topic into a prompt. The direct command
    /// must retain a qualified action/step/task/slice label, and that label must share one substantive
    /// token with a genuine User prompt from this turn.
    private static func isDeicticNextActionGrounded(
        _ candidate: String,
        by userPrompts: [String]
    ) -> Bool {
        guard firstCapture(
            #"(?i)^make\s+(?:this|that)\s+(?:the|our)\s+next((?:\s+[a-z0-9-]+){1,3})\s+(?:action|step|task|slice)[.!]?$"#,
            in: candidate
        ) != nil else { return false }
        let structuralTokens: Set<String> = ["action", "next", "slice", "step", "task"]
        let subjectTokens = Set(contentTokens(candidate)
            .subtracting(promptActionWords)
            .subtracting(structuralTokens)
            .filter { $0.count >= 4 })
        guard !subjectTokens.isEmpty else { return false }
        return userPrompts.contains { prompt in
            isDeicticProposalPrompt(prompt)
                && !subjectTokens.intersection(contentTokens(prompt)).isEmpty
        }
    }

    private static func isDeicticProposalPrompt(_ value: String) -> Bool {
        let folded = normalizedVoice(trimmed(value))
        return [
            "should we ", "should i ", "could we ", "could i ", "can we ",
            "what about ", "how about ", "would it make sense ",
            "do you think we should ",
        ].contains(where: folded.hasPrefix)
            || folded.contains(" thoughts?")
    }

    private static func isGenericNextStepPrompt(_ value: String) -> Bool {
        let key = comparisonKey(value)
        let exact: Set<String> = [
            "next", "what next", "what is next", "what s next", "what is the next action",
            "what is the next step", "what should happen next", "where do we go from here",
        ]
        if exact.contains(key) { return true }
        return firstCapture(
            #"(?i)^(what\s+should\s+(?:i|we)\s+(?:do\s+)?next\??)$"#,
            in: trimmed(value)) != nil
            || firstCapture(
                #"(?i)^(how\s+should\s+(?:i|we)\s+proceed\??)$"#,
                in: trimmed(value)) != nil
    }

    private static func containsMultipleActions(_ value: String) -> Bool {
        let folded = normalizedVoice(value)
        let isSingleAssistantOffer = [
            "if you'd like, i can ", "if you would like, i can ",
            "if you'd like, we can ", "if you would like, we can ",
        ].contains(where: folded.hasPrefix)
            || (["i can ", "we can "].contains(where: folded.hasPrefix)
                && [" if you'd like.", " if you would like."].contains(where: folded.hasSuffix))
        return value.contains(";")
            || (!isSingleAssistantOffer && folded.contains(" if "))
            || (!isSingleAssistantOffer && folded.hasPrefix("if "))
            || folded.contains(" and then ")
            || folded.contains(", then ")
    }

    private static func isPronounOnlyAction(_ value: String) -> Bool {
        let folded = normalizedVoice(strippedTerminalPunctuation(value))
        return [
            "continue", "continue it", "continue this", "do it", "do this", "proceed",
            "proceed with it", "move forward", "move ahead",
        ].contains(folded)
    }

    private static func handoffUnits(_ response: String) -> [HandoffUnit] {
        var units: [HandoffUnit] = []
        for rawLine in assistantActionSource(from: response).components(separatedBy: .newlines) {
            var line = trimmed(rawLine)
            guard !line.isEmpty, line != "…" else { continue }
            var ordinal: Int?
            var isListItem = false
            if let match = firstCaptures(#"^\s*(\d+)[.)]\s+(.+)$"#, in: line),
               let parsed = Int(match[0]) {
                ordinal = parsed
                isListItem = true
                line = match[1]
            } else if let bullet = firstCapture(#"^\s*[-*•]\s+(.+)$"#, in: line) {
                isListItem = true
                line = bullet
            }
            line = strippingLeadingMarkdownEmphasis(from: line)
            guard !isIllustrativeHandoffLine(line) else { continue }
            for sentence in splitSentences(line) {
                units.append(HandoffUnit(
                    text: sentence,
                    listOrdinal: ordinal,
                    isListItem: isListItem))
                ordinal = nil
                isListItem = false
            }
        }
        return units
    }

    /// Remove source material that may contain imperative-looking text without being an action the
    /// Assistant offered to perform. Filter the complete message before bounding it so truncation
    /// can never retain the tail of a code fence after dropping its opener.
    private static func assistantActionSource(from response: String) -> String {
        var retained: [String] = []
        var fenceMarker: String?
        var isInsideIllustrativeBlock = false
        var illustrativeHeadingLevel: Int?
        for rawLine in response.components(separatedBy: .newlines) {
            let line = trimmed(rawLine)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let marker = line.hasPrefix("```") ? "```" : "~~~"
                if fenceMarker == nil {
                    fenceMarker = marker
                } else if fenceMarker == marker {
                    fenceMarker = nil
                }
                continue
            }
            guard fenceMarker == nil else { continue }
            if isInsideIllustrativeBlock {
                // Blank lines separate paragraphs inside an example; they do not prove the example
                // has ended. Only a new Markdown section at the example's level or above is an
                // unambiguous reset; a nested "Next steps" heading can itself be example content.
                if isIllustrativeSectionHeading(line) {
                    if let currentLevel = illustrativeHeadingLevel,
                       let level = markdownHeadingLevel(rawLine) {
                        illustrativeHeadingLevel = min(currentLevel, level)
                    }
                    continue
                }
                if isExplicitActualHandoffHeading(line)
                    || (illustrativeHeadingLevel.map { exampleLevel in
                        nonIllustrativeMarkdownHeadingLevel(rawLine, line: line)
                            .map { $0 <= exampleLevel } == true
                    } == true) {
                    isInsideIllustrativeBlock = false
                } else {
                    continue
                }
            }
            if illustrativeLeadHasInlineContent(line) != nil {
                isInsideIllustrativeBlock = true
                illustrativeHeadingLevel = markdownHeadingLevel(rawLine)
                continue
            }
            if isIllustrativeSectionHeading(line) {
                isInsideIllustrativeBlock = true
                illustrativeHeadingLevel = markdownHeadingLevel(rawLine)
                continue
            }
            if rawLine.hasPrefix("\t") || rawLine.hasPrefix("    ") {
                continue
            }
            if isInlineCodeHandoffLine(line) { continue }
            if !isIllustrativeHandoffLine(strippingLeadingMarkdownEmphasis(from: line)) {
                retained.append(rawLine)
            }
        }
        return retained.joined(separator: "\n")
    }

    private static func isIllustrativeSectionHeading(_ value: String) -> Bool {
        let raw = trimmed(value)
        let line = normalizedVoice(strippingLeadingMarkdownEmphasis(from: raw))
        guard !line.isEmpty else { return false }
        let headingSyntax = raw.hasPrefix("#") || line.hasSuffix(":")
        let core = line.trimmingCharacters(in: CharacterSet(charactersIn: ":*_`# "))
        let exact: Set<String> = [
            "example", "examples", "example prompt", "example prompts", "for example",
            "example response", "example output", "for instance", "illustration", "instance",
            "instances", "sample", "samples", "sample prompt", "sample prompts",
            "suggested prompt", "previous prompt", "here is an example", "here's an example",
            "here is the exact example", "here's the exact example", "here are examples",
            "here are three examples", "some examples",
        ]
        if exact.contains(core) { return true }
        let illustrativeNouns: Set<String> = [
            "example", "examples", "instance", "instances", "sample", "samples",
        ]
        let coreWords = Set(core.split(separator: " ").map(String.init))
        let plainHeadingLead = [
            "here is ", "here's ", "here are ", "some ",
        ].contains(where: core.hasPrefix)
        if plainHeadingLead, !coreWords.intersection(illustrativeNouns).isEmpty {
            return true
        }
        guard headingSyntax else { return false }
        if [
            "example ", "example of ", "examples ", "here is an example",
            "here's an example", "here is the exact example", "here's the exact example",
            "illustrative ", "prompt example", "sample ", "samples ",
            "suggested prompt example", "suggested-prompt example",
        ].contains(where: core.hasPrefix) {
            return true
        }
        return [" example", " examples", " sample", " samples"]
            .contains(where: core.hasSuffix)
    }

    /// An illustrative lead and everything else on the same line are source material, even when a
    /// sentence boundary makes the remainder look like an independent `Next, ...` prescription.
    /// A marker with no inline content starts the same bounded illustrative block as a heading.
    private static func illustrativeLeadHasInlineContent(_ value: String) -> Bool? {
        let line = normalizedVoice(strippingLeadingMarkdownEmphasis(from: trimmed(value)))
        for marker in [
            "example", "examples", "example prompt", "example prompts", "example response",
            "example output", "sample", "samples", "sample prompt", "sample prompts",
            "sample response", "sample output", "suggested prompt", "previous prompt",
            "for example", "for instance", "as an example",
        ] {
            for separator in [".", ":"] {
                let lead = marker + separator
                if line == lead { return false }
                if line.hasPrefix(lead + " ") { return true }
            }
        }
        return nil
    }

    private static func nonIllustrativeMarkdownHeadingLevel(
        _ rawValue: String,
        line: String
    ) -> Int? {
        guard !isIllustrativeSectionHeading(line) else { return nil }
        return markdownHeadingLevel(rawValue)
    }

    private static func isExplicitActualHandoffHeading(_ value: String) -> Bool {
        let core = normalizedVoice(strippingLeadingMarkdownEmphasis(from: value))
            .trimmingCharacters(in: CharacterSet(charactersIn: ":*_`# "))
        return ["actual next step", "actual next steps"].contains(core)
    }

    private static func markdownHeadingLevel(_ rawValue: String) -> Int? {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        let count = value.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count),
              value.dropFirst(count).first?.isWhitespace == true else { return nil }
        return count
    }

    private static func isInlineCodeHandoffLine(_ value: String) -> Bool {
        var line = trimmed(value)
        if let item = firstCapture(#"^\s*(?:[-*•]|\d+[.)])\s+(.+)$"#, in: line) {
            line = trimmed(item)
        }
        while let last = line.last, ".?!:;,".contains(last) {
            line.removeLast()
            line = trimmed(line)
        }
        var removedWrapper = true
        while removedWrapper {
            removedWrapper = false
            for marker in ["***", "___", "**", "__", "*", "_"]
            where line.count > marker.count * 2
                && line.hasPrefix(marker) && line.hasSuffix(marker) {
                line = trimmed(String(line.dropFirst(marker.count).dropLast(marker.count)))
                removedWrapper = true
                break
            }
        }
        return line.count > 2 && line.hasPrefix("`") && line.hasSuffix("`")
    }

    private static func strippingLeadingMarkdownEmphasis(from value: String) -> String {
        let markers = CharacterSet(charactersIn: "*_`# ")
        var line = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = line.unicodeScalars.first, markers.contains(first) {
            line.removeFirst()
        }
        guard let colon = line.firstIndex(of: ":") else { return line }
        let label = String(line[..<colon]).trimmingCharacters(in: markers)
        let remainder = String(line[line.index(after: colon)...]).trimmingCharacters(in: markers)
        return label + ":" + (remainder.isEmpty ? "" : " " + remainder)
    }

    /// Examples, quoted prompts, and code are evidence about the answer, not instructions the
    /// suggestion bar should recursively execute.
    private static func isIllustrativeHandoffLine(_ value: String) -> Bool {
        let line = trimmed(value)
        guard !line.isEmpty else { return true }
        if line.hasPrefix(">")
            || line.hasPrefix("\"")
            || line.hasPrefix("“")
            || line.hasPrefix("'")
            || line.hasPrefix("‘") {
            return true
        }
        let folded = normalizedVoice(line)
        return [
            "example:", "example output:", "example response:", "example user:",
            "example assistant:", "prompt example:", "sample:", "sample output:",
            "sample response:", "suggested prompt example:",
            "user:", "user prompt:", "assistant:", "assistant response:",
            "suggested prompt:", "previous prompt:",
        ].contains(where: folded.hasPrefix)
    }

    private static func splitSentences(_ value: String) -> [String] {
        var result: [String] = []
        var current = ""
        let characters = Array(value)
        for index in characters.indices {
            let character = characters[index]
            current.append(character)
            let nextIndex = characters.index(after: index)
            let endsSentence = ".?!".contains(character)
                && (nextIndex == characters.endIndex || characters[nextIndex].isWhitespace)
            if endsSentence {
                let sentence = trimmed(current)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
            }
        }
        let tail = trimmed(current)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func firstCapture(_ pattern: String, in value: String) -> String? {
        firstCaptures(pattern, in: value)?.first
    }

    private static func firstCaptures(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)),
              match.range.location == 0 else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func replacingFirstMatch(
        _ pattern: String,
        in value: String,
        with replacement: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement)
    }

    private static func strippedTerminalPunctuation(_ value: String) -> String {
        var result = value
        while let last = result.last, ".?!:".contains(last) {
            result.removeLast()
            result = trimmed(result)
        }
        return result
    }

    /// Choose the first usable structured-generation alternative. Several candidates keep one
    /// small-model perspective error from suppressing the suggestion without requiring a second
    /// inference call. Nil grounding is retained only for legacy unit-level presentation-policy
    /// tests; every production caller supplies `SuggestedPromptCandidateGrounding`.
    static func firstSanitizedCandidate(
        _ rawCandidates: [String],
        avoiding latestUserPrompt: String,
        userPromptsToAvoid: [String] = [],
        grounding: SuggestedPromptCandidateGrounding? = nil
    ) -> String? {
        selectCandidate(
            rawCandidates,
            avoiding: latestUserPrompt,
            userPromptsToAvoid: userPromptsToAvoid,
            grounding: grounding).suggestion
    }

    /// Select one safe candidate while retaining content-free diagnostics for dogfood failures.
    /// Generated text is never logged or retained when every alternative is rejected. Nil grounding
    /// is a legacy/test-only surface; production must pass the final-message grounding invariant.
    static func selectCandidate(
        _ rawCandidates: [String],
        avoiding latestUserPrompt: String,
        userPromptsToAvoid: [String] = [],
        grounding: SuggestedPromptCandidateGrounding? = nil
    ) -> SuggestedPromptCandidateSelection {
        guard !rawCandidates.isEmpty else {
            return SuggestedPromptCandidateSelection(
                suggestion: nil,
                candidateCount: 0,
                rejection: .noCandidates)
        }
        var rejections: [SuggestedPromptCandidateRejection] = []
        for raw in rawCandidates {
            switch sanitize(
                raw,
                avoiding: latestUserPrompt,
                userPromptsToAvoid: userPromptsToAvoid,
                grounding: grounding
            ) {
            case .accepted(let suggestion):
                return SuggestedPromptCandidateSelection(
                    suggestion: suggestion,
                    candidateCount: rawCandidates.count,
                    rejection: nil)
            case .rejected(let rejection):
                rejections.append(rejection)
            }
        }
        let distinct = Set(rejections)
        return SuggestedPromptCandidateSelection(
            suggestion: nil,
            candidateCount: rawCandidates.count,
            rejection: distinct.count == 1 ? distinct.first : .mixed)
    }

    /// Foundation Models is constrained by instructions, but presentation still treats its output
    /// as untrusted: one line, no Markdown/preamble, bounded length, user rather than assistant
    /// voice, and never an echo of the prompt the user just sent. Optional grounding is retained for
    /// legacy presentation-policy tests only; production always supplies final-message grounding.
    static func sanitized(
        _ raw: String,
        avoiding latestUserPrompt: String,
        userPromptsToAvoid: [String] = [],
        grounding: SuggestedPromptCandidateGrounding? = nil
    ) -> String? {
        guard case .accepted(let suggestion) = sanitize(
            raw,
            avoiding: latestUserPrompt,
            userPromptsToAvoid: userPromptsToAvoid,
            grounding: grounding
        ) else { return nil }
        return suggestion
    }

    private enum SanitizationResult {
        case accepted(String)
        case rejected(SuggestedPromptCandidateRejection)
    }

    private static func sanitize(
        _ raw: String,
        avoiding latestUserPrompt: String,
        userPromptsToAvoid: [String],
        grounding: SuggestedPromptCandidateGrounding?
    ) -> SanitizationResult {
        let nonemptyLines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard nonemptyLines.count == 1 else { return .rejected(.multipleLines) }

        var suggestion = nonemptyLines[0]
        for prefix in ["Suggestion:", "Suggested prompt:", "Next prompt:"] {
            if suggestion.range(of: prefix, options: [.anchored, .caseInsensitive]) != nil {
                suggestion = String(suggestion.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        while suggestion.first == "-" || suggestion.first == "•" || suggestion.first == "*" {
            suggestion.removeFirst()
            suggestion = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if suggestion.count >= 2,
           let first = suggestion.first,
           let last = suggestion.last,
           (first == "\"" && last == "\"") || (first == "“" && last == "”") {
            suggestion.removeFirst()
            suggestion.removeLast()
            suggestion = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        suggestion = canonicalizedAssistantPermissionPrompt(suggestion)
        suggestion = canonicalizedDirectActionQuestion(suggestion)
        guard !hasAssistantPermissionVoice(suggestion) else {
            return .rejected(.assistantVoice)
        }
        guard !containsEphemeralBuildReference(suggestion) else {
            return .rejected(.ephemeralReference)
        }
        let isGroundedCandidate = grounding.map {
            isGrounded(suggestion, by: $0.allPrompts)
        } ?? false
        guard !isStatusOrVerificationInstruction(suggestion)
                || grounding.map({ isExplicitlyPrescribed(
                    suggestion,
                    by: $0.assistantHandoff)
                }) == true else {
            return .rejected(.statusInstruction)
        }
        let wordCount = comparisonKey(suggestion).split(separator: " ").count
        guard suggestion.count >= 8,
              suggestion.count <= maximumSuggestionCharacters,
              wordCount <= maximumSuggestionWords else {
            return .rejected(.invalidLength)
        }
        if grounding != nil, !isGroundedCandidate {
            return .rejected(.ungrounded)
        }
        if let grounding {
            guard isDirectActionInstruction(suggestion) else {
                return .rejected(.invalidStyle)
            }
            guard isExplicitlyPrescribed(suggestion, by: grounding.assistantHandoff) else {
                return .rejected(.notPrescribed)
            }
        }
        let promptsToAvoid = userPromptsToAvoid + [latestUserPrompt]
        guard !isPromptRestatement(
            suggestion,
            ofAny: promptsToAvoid,
            grounding: grounding
        ) else {
            return .rejected(.repeatedPrompt)
        }
        let folded = normalized(suggestion)
        guard folded != "no suggestion",
              folded != "no follow up",
              folded != "no follow-up" else {
            return .rejected(.sentinel)
        }
        return .accepted(suggestion)
    }

    /// A generated suggestion is durable conversation state. Commit hashes are deliberately not:
    /// retaining one made an old candidate look current several releases later.
    private static func containsEphemeralBuildReference(_ value: String) -> Bool {
        let hexadecimal = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return value.unicodeScalars.split(whereSeparator: {
            !CharacterSet.alphanumerics.contains($0)
        }).contains { rawToken in
            let token = String(rawToken)
            return (7...40).contains(token.count)
                && token.unicodeScalars.allSatisfy(hexadecimal.contains)
                && token.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
        }
    }

    /// Free-form generation repeatedly turned completion reports and real-life test directions
    /// into commands for the user to send back. Explicit assistant offers are handled by the
    /// compiler; the model fallback may not manufacture these status/verification directives.
    private static func isStatusOrVerificationInstruction(_ value: String) -> Bool {
        let folded = normalizedVoice(value)
        return [
            "confirm ", "please confirm ", "verify ", "please verify ",
            "validate ", "please validate ", "test ", "please test ",
            "check ", "please check ",
        ].contains(where: folded.hasPrefix)
    }

    /// Provider and local models often wrap a direct action in "Can you ...?". The suggestion bar
    /// is an action handoff, so normalize that one high-confidence shape before enforcing style.
    private static func canonicalizedDirectActionQuestion(_ value: String) -> String {
        guard let action = firstCapture(
            #"(?i)^(?:can|could|would|will)\s+you\s+(?:please\s+)?(.+?)\?$"#,
            in: value
        ), let command = renderedCommand(action, permitsOperationalCommand: true) else {
            return value
        }
        return command
    }

    private static func isDirectActionInstruction(_ value: String) -> Bool {
        guard !value.hasSuffix("?") else { return false }
        var words = comparisonKey(value).split(separator: " ").map(String.init)
        if words.first == "please" { words.removeFirst() }
        guard let first = words.first else { return false }
        return promptActionWords.contains(first)
    }

    /// A verification command is safe to ghostwrite only when the completed assistant response
    /// actually prescribes that command. Lexical overlap is insufficient: a completion report such
    /// as "I tested it; it passed" must not turn the finished test back into the next prompt.
    private static func isExplicitlyPrescribed(
        _ candidate: String,
        by assistantHandoff: String
    ) -> Bool {
        let candidateKey = directCommandKey(candidate)
        guard !candidateKey.isEmpty else { return false }
        let units = handoffUnits(assistantHandoff)
        // Descriptive rationale about the same nouns is not a handoff, so skip it. A newer terminal
        // update or a different explicit prescription is authoritative and must veto an older one.
        for index in units.indices.reversed() {
            let text = units[index].text
            if isChoiceQuestion(text) { return false }
            if isTerminalActionUpdate(text),
               terminalUpdateRefersToPriorAction(text)
                    || isGrounded(candidate, by: [text]) { return false }
            if isUserSideOperationRequest(text), isGrounded(candidate, by: [text]) { return false }
            guard let action = explicitPrescriptionAction(at: index, in: units) else { continue }
            guard let command = renderedCommand(
                action,
                permitsOperationalCommand: true,
                enforcesCharacterLimit: false) else {
                return false
            }
            return prescriptionFidelityKey(command) == candidateKey
                || isFaithfulShortening(candidate, of: command)
        }
        return false
    }

    /// The local extractor may remove articles and politeness filler from an otherwise
    /// overlong prescription, but it may not change the action, target, constraints, or numbers.
    /// Requiring the same ordered evidence-token sequence makes this an extractive shortening rather
    /// than a semantic paraphrase that could silently narrow, expand, or reverse the proposed work.
    private static func isFaithfulShortening(
        _ candidate: String,
        of prescribedCommand: String
    ) -> Bool {
        let prescribedWords = comparisonKey(prescribedCommand).split(separator: " ")
        guard prescribedCommand.count > maximumSuggestionCharacters
                || prescribedWords.count > maximumSuggestionWords,
              leadingPromptAction(in: candidate) == leadingPromptAction(in: prescribedCommand)
        else { return false }

        let candidateEvidence = shorteningEvidenceTokens(candidate)
        let prescribedEvidence = shorteningEvidenceTokens(prescribedCommand)
        return candidateEvidence.count >= 2 && candidateEvidence == prescribedEvidence
    }

    private static func shorteningEvidenceTokens(_ value: String) -> [String] {
        let normalizedContractions = normalizedVoice(value)
            .replacingOccurrences(of: "don't", with: "do not")
            .replacingOccurrences(of: "doesn't", with: "does not")
            .replacingOccurrences(of: "didn't", with: "did not")
            .replacingOccurrences(of: "can't", with: "cannot")
            .replacingOccurrences(of: "won't", with: "will not")
            .replacingOccurrences(of: "shouldn't", with: "should not")
            .replacingOccurrences(of: "wouldn't", with: "would not")
            .replacingOccurrences(of: "couldn't", with: "could not")
        let removableFiller: Set<String> = ["a", "an", "please", "the"]
        let leadingAction = leadingPromptAction(in: value)
        var removedLeadingAction = false
        return prescriptionFidelityKey(normalizedContractions).split(separator: " ").compactMap { raw in
            let word = String(raw)
            let token = stem(word)
            if !removedLeadingAction, token == leadingAction {
                removedLeadingAction = true
                return nil
            }
            return removableFiller.contains(word) ? nil : word
        }
    }

    private static func directCommandKey(_ value: String) -> String {
        let direct = replacingFirstMatch(
            #"(?i)^please\s+"#,
            in: value,
            with: "")
        guard let command = renderedCommand(direct, permitsOperationalCommand: true) else {
            return ""
        }
        return prescriptionFidelityKey(command)
    }

    /// Match the exact prescribed target while ignoring only presentation details. Internal
    /// punctuation is semantic for filenames, paths, flags, and versions and must survive.
    private static func prescriptionFidelityKey(_ value: String) -> String {
        normalizedVoice(strippedTerminalPunctuation(trimmed(value)))
    }

    private static func isTerminalActionUpdate(_ value: String) -> Bool {
        let folded = normalizedTerminalVoice(value)
        if isTersePriorActionVeto(folded) { return true }
        if ["done", "complete", "completed", "finished", "fixed", "implemented"]
            .contains(folded) || folded.hasPrefix("done ") { return true }
        let completionMarkers = [
            " is complete", " is now complete", " is already complete", " was already complete",
            " is done",
            " is already done", " was already done", " has already been done",
            " has been completed", " was completed", " already completed", " it passed",
            " has passed", " has already passed", " already passed", " succeeded",
            " is finished", " was finished", " already finished",
            " is in place now", " is now in place", " now added", " is now added",
            " is already added", " was already added", " has already been added",
            " has now been added", " has been added", " is implemented",
            " is now implemented", " is already implemented", " was implemented",
            " was already implemented", " has been implemented", " has already been implemented",
            " is fixed", " is now fixed", " is already fixed", " was fixed",
            " was already fixed", " has been fixed", " has already been fixed",
        ]
        if completionMarkers.contains(where: folded.contains) { return true }
        let cancellationMarkers = [
            "do not ", "don't ", "no longer recommend ", " no longer recommend ",
            "is no longer needed", "is not needed", "was cancelled", "was canceled",
            "is cancelled", "is canceled", "skip ", "instead of ",
        ]
        return cancellationMarkers.contains(where: {
            folded.hasPrefix($0) || folded.contains(" " + $0)
        })
    }

    /// A terse status immediately after a prescription refers back to that prescription even when
    /// it repeats none of the target nouns. Treat only closed, deictic completion shapes this way;
    /// unrelated descriptive status still needs ordinary lexical grounding before it can veto.
    private static func terminalUpdateRefersToPriorAction(_ value: String) -> Bool {
        let folded = normalizedTerminalVoice(value)
        if isTersePriorActionVeto(folded) { return true }
        if ["done", "complete", "completed", "finished", "fixed", "implemented"]
            .contains(folded) { return true }
        var key = comparisonKey(folded)
        if key.hasPrefix("actually ") { key = String(key.dropFirst("actually ".count)) }
        if ["don t do", "do not do", "skip"].contains(where: { lead in
            ["it", "that", "this"].contains(where: { key == lead + " " + $0 })
        }) { return true }
        return ["it ", "that ", "this "].contains(where: folded.hasPrefix)
            && isTerminalActionUpdate(folded)
    }

    private static func isTersePriorActionVeto(_ value: String) -> Bool {
        var key = comparisonKey(value)
        if key.hasPrefix("actually ") { key = String(key.dropFirst("actually ".count)) }
        return [
            "already done", "already complete", "already completed", "already finished",
            "added", "built", "canceled", "cancelled", "complete", "completed", "deployed",
            "done", "finished", "fixed", "implemented", "passed", "released", "removed",
            "shipped", "succeeded", "tested", "updated", "validated", "verified",
            "don t", "do not", "never mind", "scratch that",
        ].contains(key)
    }

    private static func normalizedTerminalVoice(_ value: String) -> String {
        normalizedVoice(strippedTerminalPunctuation(value))
            .replacingOccurrences(of: "that's ", with: "that is ")
            .replacingOccurrences(of: "it's ", with: "it is ")
    }

    /// The first dogfood result exposed one stable local-model role inversion. Preserve everything
    /// after its permission preamble and turn it into the command the user meant to send. This is
    /// deliberately narrower than a general rewrite: unrelated confirmation questions remain
    /// untouched and can still be valid user prompts.
    private static func canonicalizedAssistantPermissionPrompt(_ value: String) -> String {
        let pattern = #"(?i)^please\s+confirm\s+whether\s+(?:you['’]d|you\s+would)\s+like\s+to\s+proceed\s+with\s+"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: value,
                  range: NSRange(value.startIndex..., in: value)),
              match.range.location == 0,
              match.range.length < value.utf16.count,
              let remainderRange = Range(
                  NSRange(
                      location: match.range.length,
                      length: value.utf16.count - match.range.length),
                  in: value) else { return value }
        var remainder = String(value[remainderRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = remainder.last, ".?!".contains(last) {
            remainder.removeLast()
            remainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !remainder.isEmpty else { return value }
        return "Proceed with \(remainder)."
    }

    /// High-confidence forms in which the generated speaker asks the user for authorization. Keep
    /// this list narrow: "Please confirm whether the build contains X" is a direct user request and
    /// must not be mistaken for the assistant asking permission.
    private static func hasAssistantPermissionVoice(_ value: String) -> Bool {
        let folded = normalizedVoice(value)
        let forbiddenPrefixes = [
            "would you like me to ",
            "would you like us to ",
            "do you want me to ",
            "do you want us to ",
            "please confirm whether you'd like ",
            "please confirm whether you would like ",
            "please confirm if you'd like ",
            "please confirm if you would like ",
            "let me know if you'd like ",
            "let me know if you would like ",
            "please let me know if you'd like ",
            "please let me know if you would like ",
            "if you'd like, i can ",
            "if you would like, i can ",
        ]
        if forbiddenPrefixes.contains(where: folded.hasPrefix) { return true }
        if folded.contains("please confirm whether you'd like ")
            || folded.contains("please confirm whether you would like ") {
            return true
        }
        return folded.hasPrefix("i can ")
            && (folded.contains(" if you'd like")
                || folded.contains(" if you would like"))
    }

    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func normalizedVoice(_ value: String) -> String {
        normalized(value.replacingOccurrences(of: "’", with: "'"))
    }

    /// Reject high-confidence echoes in every voice. Small models often turn a User question into an
    /// imperative, add punctuation to an exact command, or copy an older command verbatim; limiting
    /// this check to question-shaped output made all three look new. Generic action words are removed
    /// before the overlap check so changing "implement" to "design" cannot disguise the same subject.
    private static func isPromptRestatement(
        _ candidate: String,
        ofAny userPrompts: [String],
        grounding: SuggestedPromptCandidateGrounding?
    ) -> Bool {
        let candidateComparison = comparisonKey(candidate)
        let candidateTokens = restatementTokens(candidate)
        let userTokenCorpus = userPrompts.reduce(into: Set<String>()) {
            $0.formUnion(restatementTokens($1))
        }
        let assistantIntroducedTokens = grounding.map {
            restatementTokens($0.assistantHandoff).subtracting(userTokenCorpus)
        } ?? []
        return userPrompts.contains { prompt in
            let promptComparison = comparisonKey(prompt)
            if candidateComparison == promptComparison { return true }
            let promptTokens = restatementTokens(prompt)
            let addsAssistantIntroducedDetail = !candidateTokens
                .subtracting(promptTokens)
                .intersection(assistantIntroducedTokens)
                .isEmpty
            let addsAssistantPrescribedAction = grounding.map { evidence in
                guard let action = leadingPromptAction(in: candidate),
                      let category = promptActionCategory(action),
                      !promptActionCategories(in: prompt).isEmpty,
                      !promptActionCategories(in: prompt).contains(category) else {
                    return false
                }
                return isExplicitlyPrescribed(candidate, by: evidence.assistantHandoff)
            } ?? false
            let advancesBeyondPrompt = addsAssistantIntroducedDetail
                || addsAssistantPrescribedAction
            if candidateTokens.count >= 2,
               candidateComparison.count >= 16,
               (promptComparison.contains(candidateComparison)
                    || candidateComparison.contains(promptComparison)),
               !advancesBeyondPrompt {
                return true
            }
            guard candidateTokens.count >= 2 else { return false }
            let overlap = candidateTokens.intersection(promptTokens).count
            return overlap >= 2
                && (overlap == candidateTokens.count
                    || (overlap >= 3
                        && Double(overlap) / Double(candidateTokens.count) >= 0.72))
                && !advancesBeyondPrompt
        }
    }

    private static func restatementTokens(_ value: String) -> Set<String> {
        let generic: Set<String> = [
            "about", "add", "again", "also", "around", "between", "better", "build",
            "complet", "continue", "create", "current", "design", "discuss", "existing",
            "first", "fix", "implement", "improve", "investigate", "make", "more", "new",
            "next", "now", "order", "please", "ready", "refactor", "remain", "review",
            "sequence", "simple", "slice", "status", "task", "then", "through", "update",
            "using", "via", "way", "work",
        ]
        let leadingAction = leadingPromptAction(in: value)
        return Set(contentTokens(value).compactMap { token in
            let canonical: String
            switch token {
            case "communicate", "communication", "messag", "message":
                canonical = "communicate"
            case "implementation": canonical = "implement"
            case "suggestion": canonical = "suggest"
            case "verification": canonical = "verify"
            default: canonical = token
            }
            return generic.contains(canonical) || canonical == leadingAction
                ? nil
                : canonical
        })
    }

    private static func leadingPromptAction(in value: String) -> String? {
        let preamble: Set<String> = [
            "action", "can", "could", "do", "i", "is", "let", "lets", "may", "me", "next",
            "please", "shall", "should", "step", "the", "to", "us", "we", "will", "would",
            "you",
        ]
        for raw in comparisonKey(value).split(separator: " ") {
            let token = stem(String(raw))
            if preamble.contains(token) { continue }
            return promptActionWords.contains(token) ? token : nil
        }
        return nil
    }

    private static func promptActionCategories(in value: String) -> Set<PromptActionCategory> {
        let expression = try? NSRegularExpression(
            pattern: #"(?i)(?:\band\s+then\b|\band\b|\bthen\b|[,;:\n])"#)
        let separated = expression?.stringByReplacingMatches(
            in: value,
            range: NSRange(value.startIndex..., in: value),
            withTemplate: "\n") ?? value
        return Set(separated.components(separatedBy: .newlines).compactMap {
            leadingPromptAction(in: $0).flatMap(promptActionCategory)
        })
    }

    private static func promptActionCategory(_ action: String) -> PromptActionCategory? {
        switch action {
        case "accept", "add", "apply", "build", "cancel", "capture", "choose", "configure",
             "connect", "convert", "create", "delete", "design", "disable", "enable", "expand",
             "expose", "extract", "fix", "generate", "guard", "harden", "implement", "improve",
             "integrate", "make", "merge", "move", "persist", "prioritize", "project",
             "refactor", "refine", "remove", "rename", "replace", "replay", "restore", "retry",
             "revert", "set", "simplify", "stop", "strengthen", "switch", "update", "use",
             "wire":
            return .implementation
        case "check", "confirm", "rebuild", "relaunch", "rerun", "run", "test", "validate",
             "verify":
            return .verification
        case "audit", "compare", "diagnose", "inspect", "investigate", "measure", "open",
             "profile", "read", "review", "trace":
            return .investigation
        case "commit", "deploy", "install", "migrate", "promote", "publish", "push", "release",
             "ship":
            return .delivery
        case "document", "draft", "record", "write":
            return .documentation
        case "complete", "continue", "finalize", "finish", "prepare", "proceed", "start":
            return .continuation
        case "discuss", "explain", "outline", "propose", "show", "suggest", "summarize", "tell":
            return .discussion
        default:
            return nil
        }
    }

    private static func comparisonKey(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : " "
        }).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func contentTokens(_ value: String) -> Set<String> {
        let stopWords: Set<String> = [
            "a", "across", "after", "an", "and", "are", "aren", "as", "at", "be", "because",
            "been", "but", "can", "could", "did", "do", "does", "don", "especially", "for",
            "from", "how", "i", "in", "into", "is", "it", "my", "not", "of", "on", "or",
            "other", "should", "still", "that", "the", "this", "to", "was", "were", "what",
            "when", "where", "which", "who", "why", "will", "with", "would", "you",
        ]
        return Set(comparisonKey(value).split(separator: " ").compactMap { raw in
            let token = stem(String(raw))
            return token.count >= 3 && !stopWords.contains(token) ? token : nil
        })
    }

    private static func stem(_ token: String) -> String {
        let irregular: [String: String] = [
            "fixed": "fix", "fixing": "fix", "ran": "run", "running": "run",
            "runs": "run", "set": "set", "sets": "set", "wired": "wire", "wiring": "wire",
        ]
        if let canonical = irregular[token] { return canonical }
        if token.count > 6, token.hasSuffix("ing") { return String(token.dropLast(3)) }
        if token.count > 5, token.hasSuffix("ed") { return String(token.dropLast(2)) }
        if token.count > 5,
           ["ches", "shes", "sses", "xes", "zes"].contains(where: { token.hasSuffix($0) }) {
            return String(token.dropLast(2))
        }
        if token.count > 4, token.hasSuffix("s") { return String(token.dropLast()) }
        return token
    }

    private static func isGenuineUser(_ entry: TranscriptEntry) -> Bool {
        entry.kind == .user
            && !trimmed(entry.text).isEmpty
            && !isSyntheticResumePrompt(entry.text)
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isSyntheticResumePrompt(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: "[wait-mode]", options: [.anchored, .caseInsensitive]) != nil
    }

    /// Synthetic wait continuations are app-owned lifecycle messages, not a user's decision to
    /// abandon the follow-up still on offer. Genuine messages retire it at the same durable send
    /// boundary as before.
    static func shouldRetireExistingSuggestion(for prompt: String) -> Bool {
        !isSyntheticResumePrompt(prompt)
    }

    private static func bounded(_ value: String, to limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let headCount = max(1, Int(Double(limit) * 0.65))
        let tailCount = max(1, limit - headCount - 3)
        return String(trimmed.prefix(headCount)) + "\n…\n" + String(trimmed.suffix(tailCount))
    }
}
