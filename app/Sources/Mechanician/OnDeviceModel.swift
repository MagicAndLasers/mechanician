import Foundation
import FoundationModels

@Generable(description: "Possible next messages written by the user to the assistant.")
private struct SuggestedPromptCandidates {
    @Guide(description: """
        Zero to three short direct actions in best-first order, each ready to insert verbatim into \
        the user's message box. Return zero when the final Assistant message does not explicitly \
        recommend, offer, or name an unfinished action.
        """, .maximumCount(3))
    var prompts: [String]
}

struct SuggestedPromptOutputDiagnostics: Equatable, Sendable {
    let candidateCount: Int
    let rejection: SuggestedPromptCandidateRejection

    var logDescription: String {
        "output_rejected candidates=\(candidateCount) rejection=\(rejection.rawValue)"
    }
}

enum SuggestedPromptGenerationResult: Equatable, Sendable {
    case suggestion(String)
    case cancelled
    case modelUnavailable
    case generationFailed
    case outputRejected(SuggestedPromptOutputDiagnostics)

    var diagnosticName: String {
        switch self {
        case .suggestion: "suggestion"
        case .cancelled: "cancelled"
        case .modelUnavailable: "model_unavailable"
        case .generationFailed: "generation_failed"
        case .outputRejected(let diagnostics): diagnostics.logDescription
        }
    }
}

/// A process-local FIFO permit for Foundation Models inference.
///
/// `LanguageModelSession` work cannot safely overlap in one process: an actor method alone would
/// become reentrant while awaiting the model and admit a second session. This gate therefore keeps
/// the occupied bit and waiter queue behind a synchronous lock, and holds the permit across the
/// caller's complete asynchronous operation.
final class OnDeviceModelExecutionGate: @unchecked Sendable {
    private typealias Waiter = CheckedContinuation<Void, Never>

    private let lock = NSLock()
    private var occupied = false
    private var waiters: [Waiter] = []

    /// Visible to the focused concurrency test and useful when diagnosing a stalled local model.
    var queuedOperationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func withPermit<T>(_ operation: () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await operation()
    }

    private func acquire() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if occupied {
                waiters.append(continuation)
                lock.unlock()
            } else {
                occupied = true
                lock.unlock()
                continuation.resume()
            }
        }
    }

    private func release() {
        let next: Waiter?
        lock.lock()
        if waiters.isEmpty {
            occupied = false
            next = nil
        } else {
            next = waiters.removeFirst()
        }
        lock.unlock()
        next?.resume()
    }
}

/// On-device Apple Intelligence (Foundation Models) — a fast, free, private model tier for small
/// jobs that shouldn't hit the cloud: naming a conversation, triaging a prompt, a one-line answer.
///
/// It's the reflex tier: best-effort. If Apple Intelligence isn't enabled or the model isn't ready,
/// every call returns nil and the caller falls back to its cloud path. Two shapes are offered —
/// plain-text `respond`, and guided-generation `generate(_:from:)` which coerces the model into a
/// `@Generable` value (no parsing, no drift).
enum OnDeviceModel {

    /// Every inference entry point in this file shares this one process-wide permit.
    private static let executionGate = OnDeviceModelExecutionGate()

    /// Whether the on-device model can be used right now.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// A short, human-readable explanation of *why* the on-device tier is (un)available — for
    /// Settings / status surfaces so the user knows whether to enable Apple Intelligence, wait for
    /// the model to finish downloading, or that their Mac simply can't run it.
    static var availabilityReason: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "On-device model ready."
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "This Mac doesn't support Apple Intelligence."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in System Settings to enable the on-device tier."
            case .modelNotReady:
                return "The on-device model is still downloading. Try again shortly."
            @unknown default:
                return "On-device model unavailable (\(String(describing: reason)))."
            }
        }
    }

    // MARK: - Plain text

    /// Run a one-shot on-device completion. Returns the trimmed text, or nil if the tier is
    /// unavailable or the model declines/errs — the caller keeps its fallback.
    /// `instructions` set the model's persona/rules; `prompt` is the turn.
    static func respond(to prompt: String, instructions: String? = nil, maxChars: Int = 4000) async -> String? {
        guard !Task.isCancelled,
              case .available = SystemLanguageModel.default.availability else { return nil }
        return await executionGate.withPermit {
            guard !Task.isCancelled,
                  case .available = SystemLanguageModel.default.availability else { return nil }
            do {
                let session = instructions.map { LanguageModelSession(instructions: $0) }
                    ?? LanguageModelSession()
                let response = try await session.respond(to: String(prompt.prefix(maxChars)))
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch {
                return nil
            }
        }
    }

    // MARK: - Guided generation

    /// Coerce the on-device model into a structured `@Generable` value — the framework constrains
    /// decoding to the type's schema, so there's no JSON to parse and no format drift. Returns nil
    /// if the tier is unavailable or generation fails.
    static func generate<T: Generable>(_ type: T.Type,
                                       from prompt: String,
                                       instructions: String? = nil,
                                       maxChars: Int = 4000) async -> T? {
        guard !Task.isCancelled,
              case .available = SystemLanguageModel.default.availability else { return nil }
        return await executionGate.withPermit {
            guard !Task.isCancelled,
                  case .available = SystemLanguageModel.default.availability else { return nil }
            do {
                let session = instructions.map { LanguageModelSession(instructions: $0) }
                    ?? LanguageModelSession()
                let response = try await session.respond(
                    to: String(prompt.prefix(maxChars)),
                    generating: type)
                return response.content
            } catch {
                return nil
            }
        }
    }

    // MARK: - Micro-tasks (built on the primitives above)

    /// A concise (3–5 word) conversation title from the opening user message, generated
    /// on-device. nil if unavailable or the model declines — the caller keeps its fallback title.
    static func title(for userText: String) async -> String? {
        let instructions = """
        You generate a concise 3–5 word title for a chat conversation, in Title Case.
        Return ONLY the title — no surrounding quotes, no trailing punctuation, no preamble.
        """
        guard let raw = await respond(
            to: "Opening message:\n\(String(userText.prefix(500)))",
            instructions: instructions
        ) else { return nil }
        return ConversationTitlePolicy.sanitizeGenerated(raw)
    }

    /// A concise on-device recap of a conversation — a few bullets of topics, decisions, and open
    /// action items. Private (never leaves the Mac), free, and offline. nil if the tier is
    /// unavailable or the model declines.
    static func summarize(_ transcript: String) async -> String? {
        let instructions = """
        You summarize a conversation between a user and an AI coding assistant. Produce a short \
        recap: 3–6 concise "- " bullets covering the key topics, decisions made, and any open \
        action items. No preamble and no closing remarks — just the bullets.
        """
        return await respond(to: "Conversation:\n\(transcript)", instructions: instructions, maxChars: 6000)
    }

    /// One plausible next message grounded in the just-completed exchange. The source material is
    /// already bounded and already crossed the current conversation's disclosure fences before it
    /// reaches this local-only model. Failure is intentionally silent: provider completion and the
    /// composer remain fully usable without Apple Intelligence.
    static func suggestedPrompt(
        from snapshot: SuggestedPromptFallbackSnapshot
    ) async -> SuggestedPromptGenerationResult {
        guard !Task.isCancelled else { return .cancelled }
        if let compiled = SuggestedPromptFallback.compiledHandoff(from: snapshot) {
            return .suggestion(compiled)
        }
        guard case .available = SystemLanguageModel.default.availability else {
            return .modelUnavailable
        }
        return await executionGate.withPermit {
            guard !Task.isCancelled else { return .cancelled }
            guard case .available = SystemLanguageModel.default.availability else {
                return .modelUnavailable
            }
            return await suggestedPromptWithPermit(from: snapshot)
        }
    }

    /// The model may restate an explicit final-message prescription when terse User wording does not
    /// lexically contain its subject. Deterministic validation still requires the same closed
    /// prescription grammar as the compiler. The model may abstain; there is no invention/repair
    /// pass.
    private static func suggestedPromptWithPermit(
        from snapshot: SuggestedPromptFallbackSnapshot
    ) async -> SuggestedPromptGenerationResult {
        let instructions = """
        Extract the newest unfinished action that the final Assistant message explicitly \
        recommends, offers to perform, or names as the next step. Write it as a short direct \
        imperative from the User to the assistant, beginning with an action verb. Prefer 3–12 \
        words. Do not ask a question, brainstorm a new direction, elaborate an example, or reuse \
        text quoted as a User prompt, Suggested prompt, example, or code. Do not use earlier \
        Assistant progress or recalled memory as an action source. Do not invent a repository, \
        project, file, tool, preference, result, identifier, or permission request. Return no \
        alternatives unless the final Assistant message itself prescribes a concrete action. Each \
        alternative is one plain-text line with no label or explanation.
        """
        let grounding = snapshot.candidateGrounding
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: String(snapshot.context.prefix(
                    SuggestedPromptFallback.maximumContextCharacters)),
                generating: SuggestedPromptCandidates.self)
            guard !Task.isCancelled else { return .cancelled }
            let selection = SuggestedPromptFallback.selectCandidate(
                response.content.prompts,
                avoiding: snapshot.latestUserPrompt,
                userPromptsToAvoid: snapshot.userPromptsToAvoid,
                grounding: grounding)
            if let suggestion = selection.suggestion {
                return .suggestion(suggestion)
            }
            return .outputRejected(SuggestedPromptOutputDiagnostics(
                candidateCount: selection.candidateCount,
                rejection: selection.rejection ?? .mixed))
        } catch {
            return Task.isCancelled ? .cancelled : .generationFailed
        }
    }
}
