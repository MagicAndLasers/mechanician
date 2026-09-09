import Foundation

/// Provenance is persisted so a late asynchronous title can never overwrite a human rename.
/// `legacy` is intentionally conservative: old sidecars do not say whether their title came from
/// the model or the person, so only an explicit Regenerate Title action may replace one.
enum ConversationTitleSource: String, Codable, Equatable {
    case placeholder
    case fallback
    case generated
    case manual
    case legacy
}

/// Pure normalization shared by the instant first-prompt fallback and Apple Intelligence output.
/// Model instructions are not a data boundary: local models can still return prose, Markdown, or a
/// refusal, so every generated title passes this policy before reaching a conversation sidecar.
enum ConversationTitlePolicy {
    static let placeholder = "New conversation"
    static let maximumCharacters = 60

    static func canReplaceAutomatically(_ source: ConversationTitleSource) -> Bool {
        source == .placeholder || source == .fallback
    }

    static func fallback(from openingMessage: String) -> String {
        for rawLine in normalizedLines(openingMessage) {
            let candidate = cleanLine(rawLine)
            if !candidate.isEmpty {
                return clipped(candidate)
            }
        }
        return placeholder
    }

    static func sanitizeGenerated(_ raw: String) -> String? {
        var insideCodeFence = false
        var codeFenceHasLanguage = false
        for rawLine in normalizedLines(raw) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if insideCodeFence {
                    insideCodeFence = false
                    codeFenceHasLanguage = false
                } else {
                    let marker = trimmed.hasPrefix("```") ? "```" : "~~~"
                    insideCodeFence = true
                    codeFenceHasLanguage = !trimmed.dropFirst(marker.count)
                        .trimmingCharacters(in: .whitespaces).isEmpty
                }
                continue
            }
            if insideCodeFence && codeFenceHasLanguage { continue }

            var candidate = cleanLine(rawLine)
            guard !candidate.isEmpty else { continue }

            let lower = candidate.lowercased()
            let preamble = lower.trimmingCharacters(
                in: CharacterSet(charactersIn: " \t.,;:!?–—-"))
            if generatedPreambles.contains(where: {
                preamble == $0 || preamble.hasPrefix($0 + " ")
            }) {
                continue
            }
            if refusalFragments.contains(where: {
                lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + ",")
            }) {
                return nil
            }

            candidate = candidate.trimmingCharacters(
                in: CharacterSet(charactersIn: " \t.,;:!?–—-"))
            guard !candidate.isEmpty else { continue }
            if candidate == candidate.uppercased(), candidate != candidate.lowercased() {
                candidate = candidate.capitalized
            }
            return clipped(candidate)
        }
        return nil
    }

    private static let generatedPreambles = [
        "here is a title",
        "here is the title",
        "here's a title",
        "here's the title",
        "a concise title",
        "suggested title",
        "conversation title",
    ]

    private static let refusalFragments = [
        "i can't",
        "i cannot",
        "i can’t",
        "i am unable",
        "i'm unable",
        "i’m unable",
        "i'm sorry",
        "i’m sorry",
        "i am sorry",
        "unable to provide",
        "cannot provide",
        "can't provide",
        "can’t provide",
        "as an ai",
        "sorry",
    ]

    private static func normalizedLines(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func cleanLine(_ raw: String) -> String {
        var value = collapsedWhitespace(raw)
        guard !value.isEmpty else { return "" }
        if value.hasPrefix("```") || value.hasPrefix("~~~") { return "" }

        value = stripListOrHeadingPrefix(value)
        value = stripWrappers(value)
        value = stripLabel(value)
        value = stripWrappers(value)
        value = value.replacingOccurrences(of: "`", with: "")
        value = value.replacingOccurrences(of: "**", with: "")
        return collapsedWhitespace(value)
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripListOrHeadingPrefix(_ raw: String) -> String {
        var value = raw
        while let first = value.first, "#>•".contains(first) {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespaces)
        }
        if value.hasPrefix("- ") || value.hasPrefix("* ") || value.hasPrefix("+ ") {
            value.removeFirst(2)
        } else if let range = value.range(
            of: #"^\d+[\.\)]\s+"#,
            options: .regularExpression
        ) {
            value.removeSubrange(range)
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func stripLabel(_ raw: String) -> String {
        let labels = [
            "conversation title:", "conversation title -", "conversation title –",
            "conversation title —", "suggested title:", "suggested title -",
            "suggested title –", "suggested title —", "title:", "title -", "title –", "title —",
        ]
        let lower = raw.lowercased()
        guard let label = labels.first(where: { lower.hasPrefix($0) }) else { return raw }
        return String(raw.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func stripWrappers(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs = [
            ("**", "**"), ("__", "__"), ("`", "`"), ("\"", "\""), ("'", "'"),
            ("“", "”"), ("‘", "’"), ("*", "*"), ("_", "_"),
        ]
        var changed = true
        while changed {
            changed = false
            for (opening, closing) in pairs
                where value.hasPrefix(opening)
                    && value.hasSuffix(closing)
                    && value.count > opening.count + closing.count {
                value = String(value.dropFirst(opening.count).dropLast(closing.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        return value
    }

    private static func clipped(_ raw: String) -> String {
        guard raw.count > maximumCharacters else { return raw }
        let prefix = String(raw.prefix(maximumCharacters))
        guard let boundary = prefix.lastIndex(of: " "),
              prefix.distance(from: prefix.startIndex, to: boundary) >= maximumCharacters / 2 else {
            return prefix
        }
        return String(prefix[..<boundary])
    }
}
