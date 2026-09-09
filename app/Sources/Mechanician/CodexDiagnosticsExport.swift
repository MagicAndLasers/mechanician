import Foundation

enum CodexDiagnosticsExportError: LocalizedError {
    case invalidEnvelope
    case unavailable
    case runtimeStopped
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope:
            return "Codex returned an invalid diagnostics envelope."
        case .unavailable:
            return "Connect the Codex subscription runtime before exporting diagnostics."
        case .runtimeStopped:
            return "Codex restarted before the diagnostics export finished."
        case .timedOut:
            return "Codex did not return diagnostics in time."
        }
    }
}

/// Defense-in-depth sanitizer for the user-controlled Codex lifecycle export.
///
/// agentd already builds the trace from an allowlist. Reconstructing the JSON again in Swift means
/// a future daemon regression cannot smuggle prompts, model output, tool payloads, environment
/// values, or credentials into a file the UI labels as redacted.
enum CodexDiagnosticsExport {
    static let format = "ai.mechanician.codex-lifecycle.v1"
    static let maximumEntries = 256

    private static let entryKeys: Set<String> = [
        "recordedAt", "monotonicMs", "runtimeId", "codexVersion", "schemaHash",
        "processGeneration", "clientTurnId", "conversationHash", "provider", "auth",
        "model", "effort", "threadId", "turnId", "event", "previousState", "nextState",
        "reason", "method", "providerStatus", "threadStatus", "activeFlags", "failureCount",
        "errorCode", "errorMethod", "result", "restartReason", "requestTimeoutMs",
    ]
    private static let numericEntryKeys: Set<String> = [
        "monotonicMs", "processGeneration", "failureCount", "requestTimeoutMs",
    ]

    static var defaultFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Mechanician-Codex-Diagnostics-\(formatter.string(from: Date())).json"
    }

    static func encoded(_ raw: Any) throws -> Data {
        guard let envelope = raw as? [String: Any],
              envelope["format"] as? String == format,
              let rawEntries = envelope["entries"] as? [[String: Any]],
              rawEntries.count <= maximumEntries else {
            throw CodexDiagnosticsExportError.invalidEnvelope
        }

        let entries = rawEntries.map(sanitizeEntry)
        let rawRuntime = envelope["runtime"] as? [String: Any] ?? [:]
        var runtime: [String: Any] = [:]
        if let value = boundedString(rawRuntime["runtimeId"], maximum: 128) {
            runtime["runtimeId"] = value
        }
        if let value = boundedString(rawRuntime["codexVersion"], maximum: 64) {
            runtime["codexVersion"] = value
        }
        if let value = boundedString(rawRuntime["schemaHash"], maximum: 128) {
            runtime["schemaHash"] = value
        }
        if let value = finiteNumber(rawRuntime["processGeneration"]) {
            runtime["processGeneration"] = value
        }
        let exportedAt = boundedString(envelope["exportedAt"], maximum: 64)
            ?? ISO8601DateFormatter().string(from: Date())
        let sanitized: [String: Any] = [
            "format": format,
            "exportedAt": exportedAt,
            "redaction": [
                "prompts": "excluded",
                "output": "excluded",
                "toolPayloads": "excluded",
                "environment": "excluded",
                "credentials": "excluded",
                "conversationIdentifiers": "sha256-prefix",
            ],
            "runtime": runtime,
            "entryCount": entries.count,
            "maximumEntryCount": maximumEntries,
            "entries": entries,
        ]
        guard JSONSerialization.isValidJSONObject(sanitized) else {
            throw CodexDiagnosticsExportError.invalidEnvelope
        }
        var data = try JSONSerialization.data(
            withJSONObject: sanitized,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    static func write(_ raw: Any, to destination: URL) throws {
        try encoded(raw).write(to: destination, options: .atomic)
    }

    private static func sanitizeEntry(_ raw: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in entryKeys {
            guard let value = raw[key] else { continue }
            if key == "activeFlags", let values = value as? [Any] {
                result[key] = values.prefix(8).compactMap {
                    boundedString($0, maximum: 64)
                }
            } else if numericEntryKeys.contains(key), let number = finiteNumber(value) {
                result[key] = number
            } else if key == "errorCode", let number = finiteNumber(value) {
                result[key] = number
            } else if let string = boundedString(
                value,
                maximum: key == "restartReason" ? 512 : 160
            ) {
                result[key] = string
            }
        }
        return result
    }

    private static func boundedString(_ value: Any?, maximum: Int) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return String(string.prefix(maximum))
    }

    private static func finiteNumber(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return nil }
        return number
    }
}
