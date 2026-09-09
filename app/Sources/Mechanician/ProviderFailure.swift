import Foundation

/// Persisted, provider-neutral detail for a terminal provider failure.
///
/// The runtime/turn route is authoritative. Wire `provider` and `access` fields are used only as
/// consistency checks, never as routing input; conflicting or incomplete metadata is rejected so a
/// background failure cannot inherit the provider currently visible in the window.
struct ProviderFailure: Codable, Equatable {
    static var googleReauthenticationTitle: String {
        String(localized: "Google reauthentication required")
    }

    static var googleReauthenticationActionLabel: String {
        String(localized: "Reauthenticate with Google")
    }

    static var googleWorkspaceReauthenticationMessage: String {
        String(localized:
            "Your organization requires you to sign in to Google again. Reauthenticate with Google to continue using Google Vertex.")
    }

    static var googleVertexRejectedSignInMessage: String {
        String(localized:
            "Your Google sign-in expired or was revoked. Reauthenticate with Google to continue using Google Vertex.")
    }

    enum Kind: String, Codable {
        case authentication
        case quota
        case rateLimit = "rate_limit"
        case modelAccess = "model_access"
        case contextLimit = "context_limit"
        case outputLimit = "output_limit"
        case server
        case network
        case invalidRequest = "invalid_request"
        case unknown
    }

    enum Provider: String, Codable {
        case anthropic
        case codex
        case openAI = "openai"
    }

    struct RateLimitDimension: Codable, Equatable {
        var limit: Int? = nil
        var remaining: Int? = nil
        var resetAfterSeconds: Double? = nil

        fileprivate var isEmpty: Bool {
            limit == nil && remaining == nil && resetAfterSeconds == nil
        }
    }

    struct RateLimits: Codable, Equatable {
        var requests: RateLimitDimension? = nil
        var tokens: RateLimitDimension? = nil
        var project: RateLimitDimension? = nil

        fileprivate var isEmpty: Bool {
            requests == nil && tokens == nil && project == nil
        }
    }

    struct Details: Codable, Equatable {
        var code: String? = nil
        var providerType: String? = nil
        var parameter: String? = nil
        var status: Int? = nil
        var requestID: String? = nil
        var clientRequestID: String? = nil
        var retryAfterSeconds: Double? = nil
        var resetsAt: Date? = nil
        var codexErrorTag: String? = nil
        var terminalReason: String? = nil
        /// App-owned recovery identity for a provider failure. Unlike the provider's free-form
        /// `code`, this value is minted by agentd and is therefore safe to use for behavior.
        var diagnosticCode: String? = nil
        /// A no-output recovery is safe only when all three facts are explicit. Optional keeps
        /// already-persisted cards compatible and, more importantly, makes missing evidence fail
        /// closed rather than inferring safety from error prose.
        var resumed: Bool? = nil
        var noProviderWork: Bool? = nil
        var freshReplayAttempted: Bool? = nil
        var rateLimits: RateLimits? = nil

        fileprivate var isEmpty: Bool {
            code == nil && providerType == nil && parameter == nil && status == nil
                && requestID == nil && clientRequestID == nil && retryAfterSeconds == nil
                && resetsAt == nil && codexErrorTag == nil && terminalReason == nil
                && diagnosticCode == nil && resumed == nil && noProviderWork == nil
                && freshReplayAttempted == nil
                && rateLimits == nil
        }
    }

    struct ResourceLink: Identifiable {
        let id: String
        let label: String
        let systemImage: String
        let url: URL
    }

    enum AccountRecoveryAction: Equatable {
        /// Let current account state choose between a first-time Connect and a Reconnect.
        case automatic
        /// Always start a new provider login, even if the runtime still sees credentials on disk.
        case forceReconnect
    }

    struct AccountRecoveryPresentation: Equatable {
        let action: AccountRecoveryAction
        let label: String
        let help: String
    }

    /// A context-limit failure cannot be repaired by repeating the same request or reconnecting an
    /// account. Keep this presentation provider-neutral so persisted cards immediately inherit the
    /// useful recovery action without adding another wire field.
    struct ConversationRecoveryPresentation: Equatable {
        let editLabel: String
        let editHelp: String
        let startFreshLabel: String
        let startFreshHelp: String
        let startFreshEmptyLabel: String
        let startFreshEmptyHelp: String
        let guidance: String
    }

    /// Codex reports model saturation as a server failure, but presenting it as a generic service
    /// error hides both the actionable cause and the useful recovery. Derive this from the stable
    /// structured tag so already-persisted cards improve without a migration.
    struct ModelCapacityPresentation: Equatable {
        let title: String
        let guidance: String
        let diagnostic: String
    }

    let kind: Kind
    let provider: Provider
    let access: ModelAccess
    let message: String
    /// App-owned identity captured from the immutable turn route. The provider event is not trusted
    /// for routing facts, and the conversation's current selection may change before this card is
    /// viewed. Optional keeps historical transcript rows backward compatible.
    var attemptedModelID: String? = nil
    var details: Details? = nil
    /// The provider exhausted its automatic credential recovery and requires a new interactive
    /// sign-in. Optional for backward-compatible decoding of already-persisted transcript cards.
    var reconnectRequired: Bool? = nil
    /// `false` is persisted only when provider-neutral wire metadata was present but could not be
    /// reconciled with the authoritative turn route. Missing means the ordinary kind-based policy,
    /// preserving already-saved failures from before this hardening field existed.
    var retryAllowedOverride: Bool? = nil

    var providerName: String {
        switch provider {
        case .anthropic:
            return access == .claudeSubscription ? "Claude"
                : access == .claudeVertex ? "Google Vertex" : "Anthropic"
        case .codex: return "Codex"
        case .openAI: return "OpenAI"
        }
    }

    private var normalizedCodexErrorTag: String? {
        guard let tag = details?.codexErrorTag else { return nil }
        let normalized = tag.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized.isEmpty ? nil : normalized
    }

    private static let codexSubscriptionBackend404DiagnosticCode =
        "codex_subscription_backend_404"

    /// The daemon now tags this exact App Server failure, but recognize the old bounded wire form
    /// too so an already-persisted card immediately gains useful copy after an app update. This
    /// controls presentation only; retry behavior remains the normal server/unknown policy.
    private var isCodexSubscriptionBackend404: Bool {
        guard provider == .codex, access == .codexSubscription else { return false }
        let diagnosticCode = details?.diagnosticCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if diagnosticCode == Self.codexSubscriptionBackend404DiagnosticCode { return true }

        let text = message.lowercased()
        let has404 = text.contains("unexpected status 404") || text.contains("http error: 404")
        let hasEndpoint = text.contains("https://chatgpt.com/backend-api/codex/models")
            || text.contains("https://chatgpt.com/backend-api/codex/responses")
            || text.contains("wss://chatgpt.com/backend-api/codex/models")
            || text.contains("wss://chatgpt.com/backend-api/codex/responses")
        return has404 && hasEndpoint
    }

    private static var codexSubscriptionBackend404Message: String {
        String(localized:
            "The Codex subscription connection received HTTP 404 for an internal service request. Your prompt was not rejected. Retry in a moment; if it persists, check OpenAI status or Codex Help.")
    }

    var isModelCapacityFailure: Bool {
        provider == .codex
            && access == .codexSubscription
            && kind == .server
            && normalizedCodexErrorTag == "serveroverloaded"
    }

    var modelCapacityPresentation: ModelCapacityPresentation? {
        guard isModelCapacityFailure,
              let tag = details?.codexErrorTag else { return nil }
        let title = String(localized: "Selected model is at capacity")
        let model = attemptedModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var guidance: String
        if let model, !model.isEmpty {
            guidance = String(localized:
                "Codex can’t serve \(model) right now. Choose another model, or try this model again later.")
        } else {
            guidance = String(localized:
                "Codex can’t serve the selected model right now. Choose another model, or try again later.")
        }
        guidance += " " + String(localized:
            "This turn may already have completed work, so review the transcript before sending the prompt again.")
        return ModelCapacityPresentation(
            title: title,
            guidance: guidance,
            diagnostic: String(localized: "Codex error: \(tag)"))
    }

    func attributingAttemptedModel(_ modelID: String?) -> ProviderFailure {
        var attributed = self
        attributed.attemptedModelID = Self.boundedString(modelID)
        return attributed
    }

    private var normalizedCredentialEvidence: String {
        [details?.code, details?.providerType, details?.codexErrorTag, message]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    /// A configured Vertex account whose grant was rejected needs Google's browser reauth flow,
    /// which is more specific than the generic Connect/Reconnect language used for other accounts.
    /// Infer the embedded OAuth payload too so cards persisted by builds that called it `unknown`
    /// become actionable immediately after upgrading. Keep a genuinely missing first-time
    /// credential on the ordinary Connect path.
    var requiresGoogleReauthentication: Bool {
        guard access == .claudeVertex else { return false }
        let evidence = normalizedCredentialEvidence
        if evidence.contains("credentialnocredentials")
            || evidence.contains("credentialsmissing") {
            return false
        }
        if kind == .authentication { return true }
        return evidence.contains("invalidrapt")
            || evidence.contains("raptrequired")
            || evidence.contains("reauthrelatederror")
            || evidence.contains("invalidgrant")
    }

    /// Claude and Vertex authentication failures require the provider's interactive recovery.
    /// Infer known Vertex and Codex credential failures as well as honoring their structured signals
    /// so error cards persisted by older Mechanician builds gain the recovery action too.
    var requiresReconnect: Bool {
        if requiresGoogleReauthentication { return true }
        guard kind == .authentication else { return false }
        if access == .claudeSubscription || access == .claudeVertex { return true }
        guard access == .codexSubscription else { return false }
        if reconnectRequired == true { return true }
        let evidence = normalizedCredentialEvidence
        return evidence.contains("tokenrevoked")
            || evidence.contains("refreshtokeninvalidated")
            || (evidence.contains("refreshtoken") && evidence.contains("revoked"))
            || evidence.contains("recoveryfailedpermanent")
    }

    var reauthenticationActionLabel: String? {
        requiresGoogleReauthentication ? Self.googleReauthenticationActionLabel : nil
    }

    /// A failed Claude credential probe is deliberately not account-disconnecting evidence: the
    /// provider may still accept the configured session on the next attempt. Still offer an
    /// explicit fresh login so the user is not trapped behind Retry when the local credential
    /// helper itself is unavailable. This is narrower than a generic network/server failure and
    /// relies on the credential preflight namespace emitted by agentd.
    private var offersClaudeCredentialProbeReconnect: Bool {
        guard access == .claudeSubscription, !requiresReconnect else { return false }
        switch details?.providerType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "credential_unknown", "credential_network":
            return true
        default:
            return false
        }
    }

    /// A RAPT card promises a fresh interactive Google session. The generic Connect path is allowed
    /// to accept an already-loaded credential, so it cannot fulfill that promise during startup
    /// races or when rendering a failure persisted by an older build.
    func accountRecoveryAction(accountRequiresReconnect: Bool) -> AccountRecoveryAction? {
        // Account state can change after a card is persisted, but an unrelated context-limit card
        // must never turn into a Reconnect prompt. Reauth does not reduce the conversation and
        // competes with the one action that can actually recover this request.
        if kind == .contextLimit { return nil }
        // The account remains configured after an inconclusive Claude probe, so the automatic
        // Connect/Reconnect policy may return no action. Bypass it and start a real fresh login.
        if offersClaudeCredentialProbeReconnect { return .forceReconnect }
        guard requiresReconnect || accountRequiresReconnect else { return nil }
        if requiresGoogleReauthentication
            || (access == .claudeVertex && accountRequiresReconnect) {
            return .forceReconnect
        }
        return .automatic
    }

    /// Keep the visible promise aligned with the operation. In particular, a forced reconnect must
    /// not inherit "Connect" merely because a persisted card rendered while account status was
    /// still checking; clicking it always starts a fresh provider login.
    func accountRecoveryPresentation(
        accountRequiresReconnect: Bool,
        automaticActionLabel: String?
    ) -> AccountRecoveryPresentation? {
        guard let action = accountRecoveryAction(
            accountRequiresReconnect: accountRequiresReconnect
        ) else { return nil }
        if requiresGoogleReauthentication {
            return AccountRecoveryPresentation(
                action: action,
                label: reauthenticationActionLabel ?? Self.googleReauthenticationActionLabel,
                help: "Open Google sign-in to reauthenticate")
        }
        return AccountRecoveryPresentation(
            action: action,
            label: action == .forceReconnect
                ? "Reconnect"
                : automaticActionLabel ?? "Reconnect",
            help: "Sign in to \(access.displayName) again")
    }

    var conversationRecoveryPresentation: ConversationRecoveryPresentation? {
        guard kind == .contextLimit else { return nil }
        let guidance = isPromptPreflightLimit
            ? "This prompt is too large even without earlier conversation history. Edit it to remove or split large pasted text and attachments before sending again. Reconnecting or starting fresh with it unchanged won’t help."
            : "This request is larger than the model can accept. Shorten or split large pasted text and attachments, or start fresh to drop earlier history. Reconnecting won’t help."
        return ConversationRecoveryPresentation(
            editLabel: "Edit Prompt",
            editHelp: "Remove the rejected turn and restore its prompt for editing",
            startFreshLabel: "Start Fresh with Prompt",
            startFreshHelp: "Open a new conversation with the failed prompt ready to edit",
            startFreshEmptyLabel: "Start Fresh",
            startFreshEmptyHelp: "Open a new empty conversation without replaying this history",
            guidance: guidance)
    }

    var isPromptPreflightLimit: Bool {
        guard kind == .contextLimit else { return false }
        return details?.providerType?.lowercased() == "input_too_large"
            || details?.code?.lowercased() == "prompt_preflight_limit"
    }

    /// The daemon exhausted one automatic bounded replay after a resumed Claude session returned
    /// no model/tool output. A manual retry may retire the opaque session and replay the bounded
    /// durable transcript, but only when the wire proves that no provider work occurred. Never
    /// classify this from `message`: provider prose is neither stable nor an authorization fact.
    var isResumedNoOutputFailure: Bool {
        guard provider == .anthropic,
              kind == .network,
              details?.providerType?.lowercased() == "provider_no_output",
              details?.resumed == true,
              details?.noProviderWork == true,
              details?.freshReplayAttempted == true,
              details?.diagnosticCode?.trimmingCharacters(
                  in: .whitespacesAndNewlines).lowercased()
                  == "claude_no_output_after_fresh_replay",
              details?.code?.trimmingCharacters(
                  in: .whitespacesAndNewlines).lowercased()
                  == "no_output_after_fresh_replay" else { return false }
        return true
    }

    var userFacingMessage: String {
        if isCodexSubscriptionBackend404 {
            return Self.codexSubscriptionBackend404Message
        }
        if kind == .contextLimit {
            return isPromptPreflightLimit
                ? "The prompt itself is larger than the model can accept in one request."
                : "The conversation history and this request no longer fit in the model’s context window."
        }
        guard requiresGoogleReauthentication else { return message }
        let evidence = normalizedCredentialEvidence
        if evidence.contains("invalidrapt")
            || evidence.contains("raptrequired")
            || evidence.contains("reauthrelatederror")
            || evidence.contains("credentialreauthrequired") {
            return Self.googleWorkspaceReauthenticationMessage
        }
        return Self.googleVertexRejectedSignInMessage
    }

    var title: String {
        if isCodexSubscriptionBackend404 {
            return String(localized: "Codex service connection failed")
        }
        if requiresGoogleReauthentication { return Self.googleReauthenticationTitle }
        if let capacity = modelCapacityPresentation { return capacity.title }
        switch kind {
        case .authentication: return "\(access.displayName) sign-in required"
        case .quota: return "\(providerName) quota reached"
        case .rateLimit: return "\(providerName) rate limit reached"
        case .modelAccess: return "Selected model is unavailable"
        case .contextLimit:
            return isPromptPreflightLimit
                ? "Prompt is too large"
                : "Conversation exceeds the model context"
        case .outputLimit: return "Response reached its output limit"
        case .server: return "\(providerName) service error"
        case .network: return "Couldn’t reach \(providerName)"
        case .invalidRequest: return "\(providerName) rejected the request"
        case .unknown: return "\(providerName) request failed"
        }
    }

    /// When a throttled request may be sent again, if the provider said so.
    ///
    /// Only an absolute instant is usable here. `retryAfterSeconds` is relative to the response that
    /// carried it, and a `ProviderFailure` records no arrival time, so a persisted failure could not
    /// turn it into an instant without inventing a base time and claiming a precision it lacks.
    var retryAvailableAt: Date? {
        guard kind == .rateLimit else { return nil }
        return details?.resetsAt
    }

    /// Retrying cannot repair credentials, billing, entitlement, context, or request-shape faults.
    ///
    /// Throttling is the one exception, and it used to be refused with the reasoning that a button
    /// could immediately fail again. That objection is answerable with data the app already parses:
    /// when the provider states when the limit resets, retrying is a real offer rather than a guess,
    /// so the person is not made to re-send by hand for no reason. This stays a pure policy answer
    /// about the FAILURE; whether the reset has actually arrived is a question about the clock, and
    /// `AgentBridge.canRetryProviderFailure` asks it there.
    var allowsRetry: Bool {
        // A capacity error can arrive after the provider already emitted assistant/tool work, and
        // Codex does not currently provide an app-owned proof that no such work occurred. Keep the
        // recovery explicit instead of offering a one-click replay that could duplicate effects.
        if isModelCapacityFailure { return false }
        if let retryAllowedOverride { return retryAllowedOverride }
        if requiresReconnect { return false }
        // OpenAI deliberately classifies a bare HTTP 403 as unknown because its meaning varies
        // (policy, organization, project, or entitlement). Repeating the same forbidden request is
        // still not useful, even though the provider did not supply a more specific error code.
        if kind == .unknown, details?.status == 403 { return false }
        switch kind {
        case .server, .network, .unknown: return true
        case .rateLimit: return retryAvailableAt != nil
        case .authentication, .quota, .modelAccess, .contextLimit, .outputLimit,
             .invalidRequest:
            return false
        }
    }

    var diagnosticCommand: String? {
        switch access {
        case .claudeSubscription, .claudeVertex: return kind == .quota || kind == .rateLimit ? "/status" : nil
        // Bedrock quota is an AWS service quota, not something a Claude slash command reports.
        case .claudeBedrock: return nil
        case .codexSubscription: return kind == .quota || kind == .rateLimit ? "/usage" : nil
        case .anthropicAPI, .openAIAPI: return nil
        }
    }

    /// A terminal reason sometimes repeats the provider error code verbatim. Showing both leaves
    /// a confusing `Code api_error · api_error` diagnostic without adding any useful evidence.
    var diagnosticSummary: String? {
        var parts: [String] = []
        if let capacity = modelCapacityPresentation {
            parts.append(capacity.diagnostic)
        }
        if let status = details?.status { parts.append("HTTP \(status)") }
        let code = details?.code?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let code, !code.isEmpty { parts.append("Code \(code)") }
        if let parameter = details?.parameter { parts.append("Parameter \(parameter)") }
        if let terminalReason = details?.terminalReason,
           terminalReason.caseInsensitiveCompare(code ?? "") != .orderedSame {
            parts.append(terminalReason)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Provider-owned account, status, and help destinations. These are deliberately computed, not
    /// persisted, so old transcript rows inherit corrected destinations without a migration.
    var resourceLinks: [ResourceLink] {
        var result: [ResourceLink] = []
        func add(_ id: String, _ label: String, _ icon: String, _ rawURL: String) {
            guard let url = URL(string: rawURL) else { return }
            result.append(ResourceLink(id: id, label: label, systemImage: icon, url: url))
        }

        if requiresGoogleReauthentication {
            add(
                "google-cloud-reauth",
                "Why Google requires sign-in",
                "questionmark.circle",
                "https://cloud.google.com/docs/authentication/reauthentication"
            )
        }

        switch (access, kind) {
        case (.openAIAPI, .authentication):
            add("openai-keys", "Open API keys", "key", "https://platform.openai.com/settings/organization/api-keys")
        case (.openAIAPI, .quota):
            add("openai-billing", "Open billing", "creditcard", "https://platform.openai.com/settings/organization/billing")
        case (.openAIAPI, .rateLimit), (.openAIAPI, .modelAccess):
            add("openai-limits", "Open limits", "gauge.with.dots.needle.67percent", "https://platform.openai.com/settings/organization/limits")
        case (.anthropicAPI, .authentication):
            add("anthropic-keys", "Open API keys", "key", "https://console.anthropic.com/settings/keys")
        case (.anthropicAPI, .quota), (.anthropicAPI, .rateLimit):
            add("anthropic-billing", "Open billing", "creditcard", "https://console.anthropic.com/settings/billing")
        case (.claudeSubscription, .quota), (.claudeSubscription, .rateLimit):
            add("claude-usage", "View Claude usage", "chart.bar", "https://claude.ai/settings/usage")
        default:
            break
        }

        let unknownForbidden = kind == .unknown && details?.status == 403
        if !requiresGoogleReauthentication
            && ([.rateLimit, .server, .network].contains(kind)
                || (kind == .unknown && !unknownForbidden)) {
            switch provider {
            case .anthropic:
                add("anthropic-status", "Anthropic status", "waveform.path.ecg", "https://status.anthropic.com")
            case .codex, .openAI:
                add("openai-status", "OpenAI status", "waveform.path.ecg", "https://status.openai.com")
            }
        }

        if !requiresGoogleReauthentication
            && (result.isEmpty
                || [.modelAccess, .contextLimit, .outputLimit, .invalidRequest, .unknown].contains(kind)
                || isCodexSubscriptionBackend404) {
            switch provider {
            case .anthropic:
                add("anthropic-errors", "Error help", "questionmark.circle", "https://docs.anthropic.com/en/api/errors")
            case .codex:
                add("codex-help", "Codex help", "questionmark.circle", "https://developers.openai.com/codex/")
            case .openAI:
                add("openai-errors", "Error help", "questionmark.circle", "https://developers.openai.com/api/docs/guides/error-codes")
            }
        }
        return result
    }

    static func from(event: [String: Any], authoritativeAccess access: ModelAccess) -> ProviderFailure? {
        let kindRaw = event["errorKind"] as? String
        // Claude subscription allocation limits have their own richer persisted card. Preserve that
        // contract even if a future daemon also tags the event with provider/access diagnostics.
        if kindRaw == "usage_limit", access == .claudeSubscription { return nil }
        let hasProviderNeutralMetadata = event["provider"] != nil
            || event["access"] != nil
            || event["providerError"] != nil
            || kindRaw != nil

        guard let kindRaw,
              let kind = Kind(rawValue: kindRaw),
              let accessRaw = event["access"] as? String,
              accessRaw == access.rawValue,
              let providerRaw = event["provider"] as? String,
              let provider = Provider(rawValue: providerRaw),
              provider == expectedProvider(for: access) else {
            // Preserve genuinely legacy unstructured errors (and the separate Claude subscription
            // `usage_limit` wire shape). Once provider-neutral metadata appears, however, never fall
            // through to the legacy error row and its unconditional Retry action. Bind a conservative
            // unknown failure to the turn's authoritative route and make it non-retryable.
            guard hasProviderNeutralMetadata else { return nil }
            return ProviderFailure(
                kind: .unknown,
                provider: expectedProvider(for: access),
                access: access,
                message: "Provider request failed, but its error metadata did not match this conversation.",
                retryAllowedOverride: false)
        }

        let message = boundedString(event["message"], limit: 2_048) ?? "Provider request failed."
        let raw = event["providerError"] as? [String: Any] ?? [:]
        var details = Details()
        details.code = codeString(raw["code"])
        details.providerType = boundedString(raw["providerType"])
        details.parameter = boundedString(raw["param"])
        details.status = integer(raw["status"])
        details.requestID = boundedString(raw["requestId"])
        details.clientRequestID = boundedString(raw["clientRequestId"])
        details.retryAfterSeconds = nonNegativeDouble(raw["retryAfterSeconds"])
        details.resetsAt = date(raw["resetsAt"])
        details.codexErrorTag = boundedString(raw["codexErrorTag"])
        details.terminalReason = boundedString(raw["terminalReason"])
        details.diagnosticCode = boundedString(raw["diagnosticCode"])
        details.resumed = raw["resumed"] as? Bool
        details.noProviderWork = raw["noProviderWork"] as? Bool
        details.freshReplayAttempted = raw["freshReplayAttempted"] as? Bool
        details.rateLimits = rateLimits(raw["rateLimits"])

        return ProviderFailure(
            kind: kind,
            provider: provider,
            access: access,
            message: message,
            details: details.isEmpty ? nil : details,
            reconnectRequired: event["reconnectRequired"] as? Bool)
    }

    private static func expectedProvider(for access: ModelAccess) -> Provider {
        switch access {
        case .claudeSubscription, .anthropicAPI, .claudeVertex, .claudeBedrock: return .anthropic
        case .codexSubscription: return .codex
        case .openAIAPI: return .openAI
        }
    }

    private static func boundedString(_ value: Any?, limit: Int = 256) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(limit))
    }

    private static func codeString(_ value: Any?) -> String? {
        if let string = boundedString(value) { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func nonNegativeDouble(_ value: Any?) -> Double? {
        let number: Double?
        if let double = value as? Double { number = double }
        else if let numberValue = value as? NSNumber { number = numberValue.doubleValue }
        else if let string = value as? String { number = Double(string) }
        else { number = nil }
        guard let number, number.isFinite, number >= 0 else { return nil }
        return number
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = nonNegativeDouble(value), number > 0 {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
        }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = fractional.date(from: string) { return result }
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        return ordinary.date(from: string)
    }

    private static func rateLimits(_ value: Any?) -> RateLimits? {
        guard let raw = value as? [String: Any] else { return nil }
        var result = RateLimits()
        result.requests = rateLimitDimension(raw["requests"])
        result.tokens = rateLimitDimension(raw["tokens"])
        result.project = rateLimitDimension(raw["project"])
        return result.isEmpty ? nil : result
    }

    private static func rateLimitDimension(_ value: Any?) -> RateLimitDimension? {
        guard let raw = value as? [String: Any] else { return nil }
        var result = RateLimitDimension()
        result.limit = integer(raw["limit"])
        result.remaining = integer(raw["remaining"])
        result.resetAfterSeconds = nonNegativeDouble(raw["resetAfterSeconds"])
        return result.isEmpty ? nil : result
    }
}

/// Turns daemon compaction diagnostics into recovery copy while retaining the original code for
/// support/debugging. This is app-owned presentation, so older persisted transcript entries gain
/// the clearer explanation as soon as they are opened by a newer build.
struct CompactionFailurePresentation: Equatable {
    let message: String
    let diagnostic: String?

    /// Plain language, and never the engine's own words.
    ///
    /// This used to end with `String(trimmed.prefix(256))` under a monospaced "Code:" label, so a
    /// provider's internal identifier was presented to a person as though it were something they
    /// could act on. Summarizing earlier messages is routine maintenance that Mechanician retries
    /// on its own, so the card should read as a status, not an alarm. The raw text still reaches
    /// the log for diagnosis.
    static func from(_ rawError: String) -> CompactionFailurePresentation {
        let trimmed = rawError.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        if !trimmed.isEmpty {
            NSLog("[context] compaction failure detail: %@", String(trimmed.prefix(512)))
        }
        if normalized.contains("too_few_groups") || normalized.contains("too few groups") {
            return CompactionFailurePresentation(
                message: "One message is too large to summarize around. Sending a shorter message, "
                    + "or starting a new conversation, will get things moving again.",
                diagnostic: nil)
        }
        return CompactionFailurePresentation(
            message: "Mechanician will try again on the next message.",
            diagnostic: nil)
    }
}

/// The runtime may report a failed automatic compaction and then terminate the same request with a
/// context-limit error. Both records remain in the transcript/activity ledger, but presenting them
/// as two independent red failures makes one recovery problem look like two. This projection folds
/// only an immediately adjacent pair, so unrelated or earlier compaction failures stay visible.
enum ContextLimitFailureProjection {
    static func precedingCompactionFailure(
        for terminalEntry: TranscriptEntry,
        in entries: [TranscriptEntry]
    ) -> CompactionFailurePresentation? {
        guard terminalEntry.providerFailure?.kind == .contextLimit,
              let terminalIndex = entries.firstIndex(where: { $0.id == terminalEntry.id }),
              terminalIndex > entries.startIndex else { return nil }
        let compaction = entries[terminalIndex - 1]
        guard compaction.kind == .compaction,
              let rawError = compaction.compactionError else { return nil }
        return CompactionFailurePresentation.from(rawError)
    }

    static func subsumesCompactionFailure(
        _ compactionEntry: TranscriptEntry,
        in entries: [TranscriptEntry]
    ) -> Bool {
        guard compactionEntry.kind == .compaction,
              compactionEntry.compactionError != nil,
              let index = entries.firstIndex(where: { $0.id == compactionEntry.id }),
              index + 1 < entries.endIndex else { return false }
        return precedingCompactionFailure(for: entries[index + 1], in: entries) != nil
    }
}
