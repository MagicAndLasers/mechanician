import Foundation
import Combine

/// Runs a saved capability from the Capabilities library, so the library is a place you can USE
/// a verb and not merely read about one.
///
/// Before this existed, a capability could only be invoked by asking an agent in chat to call it —
/// which meant the one screen dedicated to capabilities was the one place you could not run them,
/// and there was no way to check that a verb still worked without spending a turn.
///
/// The run goes to agentd's `capability_execute`, which calls the SAME `executeCapability` both
/// model lanes use. It deliberately does not shell out to `osascript` here: a second execution path
/// would drift, would skip the runCount/verification write-back, and would mean "it worked when I
/// tested it" stopped predicting "it works when the agent calls it".
@MainActor
final class CapabilityRunner: ObservableObject {
    static let shared = CapabilityRunner()

    /// The capability currently running, by name. At most one at a time: these drive real apps,
    /// and two concurrent AppleScripts against the same app is a good way to get a hang.
    @Published private(set) var running: String?
    /// The last result, keyed by capability name, so switching selection keeps each one's output.
    @Published private(set) var results: [String: Result] = [:]

    struct Result: Equatable {
        let ok: Bool
        let output: String
        let finishedAt: Date
    }

    private var continuationName: String?

    func run(_ capability: Capability, arguments: [String: String], bridge: AgentBridge?) {
        guard running == nil else { return }
        guard let bridge else {
            results[capability.name] = Result(
                ok: false,
                output: "No runtime is available. Open a conversation first, then try again.",
                finishedAt: Date())
            return
        }
        // Drop empties so an untouched optional field stays absent rather than becoming "",
        // which agentd treats as a missing required parameter.
        var payload: [String: Any] = [:]
        for param in capability.params {
            let raw = arguments[param.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !raw.isEmpty else { continue }
            payload[param.name] = coerce(raw, to: param.type)
        }
        running = capability.name
        continuationName = capability.name
        results[capability.name] = nil
        bridge.runCapability(name: capability.name, arguments: payload)
    }

    /// Numbers and booleans must survive as numbers and booleans: a JXA script that does
    /// `args.top > 5` gets a silently wrong answer from the string "10".
    private func coerce(_ raw: String, to type: String) -> Any {
        switch type.lowercased() {
        case "number", "integer", "int", "float", "double":
            if let i = Int(raw) { return i }
            if let d = Double(raw) { return d }
            return raw
        case "boolean", "bool":
            let lowered = raw.lowercased()
            if ["true", "yes", "1", "on"].contains(lowered) { return true }
            if ["false", "no", "0", "off"].contains(lowered) { return false }
            return raw
        default:
            return raw
        }
    }

    func finish(name: String, ok: Bool, output: String) {
        // A late reply from a run we already gave up on must not overwrite a newer result.
        guard continuationName == name else { return }
        results[name] = Result(ok: ok, output: output, finishedAt: Date())
        running = nil
        continuationName = nil
    }

    func clear(_ name: String) { results[name] = nil }
}
