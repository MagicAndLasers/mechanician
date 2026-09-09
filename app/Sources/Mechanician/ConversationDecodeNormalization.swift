import Foundation

/// One member that `Conversation.init(from:)` **deliberately** discards while decoding a persisted
/// sidecar.
///
/// The tolerant decode performs a handful of product-defined repairs: it drops the provider-root
/// pseudo agent, the `Codex delegation` aggregates manufactured by builds 80–86, and the provisional
/// Task rows a later workflow update supersedes. The live app does this on every load and rewrites
/// the healed sidecar through `needsStaleStatePersistence`, so these members are not part of the
/// Conversation the product can observe.
///
/// The authority migration cannot tell that apart from real loss on its own. Its structural
/// preflight compares the source JSON with the current model's canonical encoding and quarantines
/// any object path the encoding would not reproduce — which is exactly right for an unknown member
/// written by another build, and exactly wrong for a repair the product performs on purpose. An
/// undeclared repair therefore costs an ordinary Conversation its place in the migrated library.
///
/// Declaring each repair here keeps the preflight strict by default: a future normalization that
/// does not report itself still quarantines rather than silently passing.
enum ConversationDecodeNormalization: Equatable, Sendable {
    case sessionToolProfile
    case suggestedPrompt
    case workflowRun(storageKey: String)
    case subagent(storageKey: String)
    case agentActivity(id: UUID)
}

extension ConversationDecodeNormalization {
    /// Remove the declared members from an already-parsed source tree so the structural comparison
    /// sees the same shape the decoder actually produced.
    ///
    /// Removing them from the *source* rather than excusing paths in the *report* is what makes this
    /// safe for arrays: `agentActivity` is compared by position, so excusing one element by index
    /// would misalign every later element and manufacture drops that were never real. A declaration
    /// that matches nothing is a no-op, never an error — the comparison simply stays strict.
    static func prune(
        source: Any,
        applying normalizations: [ConversationDecodeNormalization]
    ) -> Any {
        guard var object = source as? [String: Any], !normalizations.isEmpty else { return source }
        var workflowRunKeys = Set<String>()
        var subagentKeys = Set<String>()
        var activityIDs = Set<String>()
        var removesSessionToolProfile = false
        var removesSuggestedPrompt = false
        for normalization in normalizations {
            switch normalization {
            case .sessionToolProfile: removesSessionToolProfile = true
            case .suggestedPrompt: removesSuggestedPrompt = true
            case .workflowRun(let key): workflowRunKeys.insert(key)
            case .subagent(let key): subagentKeys.insert(key)
            case .agentActivity(let id): activityIDs.insert(id.uuidString)
            }
        }
        if removesSessionToolProfile {
            object.removeValue(forKey: "sdkSessionToolProfile")
        }
        if removesSuggestedPrompt {
            object.removeValue(forKey: "suggestedPrompt")
        }
        if !workflowRunKeys.isEmpty {
            object["workflowRuns"] = removing(keys: workflowRunKeys, from: object["workflowRuns"])
        }
        if !subagentKeys.isEmpty {
            object["subagents"] = removing(keys: subagentKeys, from: object["subagents"])
        }
        if !activityIDs.isEmpty, let activity = object["agentActivity"] as? [Any] {
            object["agentActivity"] = activity.filter { element in
                guard let record = element as? [String: Any],
                      let id = record["id"] as? String else { return true }
                // Compare case-insensitively: `UUID.uuidString` is upper-case, and a hand-edited or
                // differently-encoded sidecar may spell the same identity in lower-case.
                return !activityIDs.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
            }
        }
        return object
    }

    private static func removing(keys: Set<String>, from value: Any?) -> Any? {
        guard var map = value as? [String: Any] else { return value }
        for key in keys { map.removeValue(forKey: key) }
        return map
    }
}
