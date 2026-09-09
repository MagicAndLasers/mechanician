import Foundation

/// The effort vocabulary, in one place, deliberately open at the top end.
///
/// Effort levels are provider-REPORTED. The daemon says so in its own comment, and then five
/// separate call sites did the opposite: each filtered the reported list against its own hardcoded
/// array, and the arrays had already drifted apart from one another. The effect was that a level
/// Anthropic or OpenAI shipped after a given build was invisible in the picker AND unsendable on the
/// wire until an app release went out, on every lane at once.
///
/// So the rule here is: bound the SHAPE, not the vocabulary. A reported level has to look like an
/// identifier before it reaches a menu row or the wire, and the count is capped, but a name this
/// build has never heard of is carried rather than dropped.
enum EffortLevels {
    /// Levels this build knows how to place on the cost ladder, cheapest first.
    ///
    /// This is an ORDERING, not a whitelist. Levels outside it are appended after it, in the order
    /// the provider reported them, because we have no basis for claiming where they sit.
    static let ladder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// `ultra` is deliberately absent from the ladder and never appended as an unknown.
    ///
    /// On Claude it is not an effort level at all: it maps to `xhigh` plus `settings.ultracode`, so
    /// rendering it as a raw selectable level would bypass `AgentBridge.ultraTurnConfiguration` and
    /// put a value on the wire the route does not take. The lanes that own Ultra surface it
    /// themselves; the generic path must never invent it.
    static let reserved = "ultra"

    /// A hostile or simply broken catalog must not be able to flood a menu. The ladder is 7 long, so
    /// this leaves generous room for levels a provider adds without ever becoming a wall of rows.
    static let maximumReported = 16

    /// Bounds the shape a reported level may take: an ASCII identifier, lowercase, reasonably short.
    /// Anything else is not a level we failed to recognize, it is malformed metadata.
    static func isWellFormed(_ name: String) -> Bool {
        guard (1...32).contains(name.count) else { return false }
        guard let first = name.first, first.isASCII, first.isLetter, first.isLowercase else {
            return false
        }
        return name.allSatisfy { character in
            character.isASCII
                && (character.isLowercase || character.isNumber
                    || character == "_" || character == "-")
        }
    }

    /// Reported levels in a stable order: the ones on the ladder first, cheapest to strongest, then
    /// anything else the provider reported, in the order it reported them.
    ///
    /// - Parameter includingReserved: whether ``reserved`` survives when reported. The sending path
    ///   needs it (`ultraTurnConfiguration` reads it); the generic picker path must not show it.
    static func ordered(reported: [String], includingReserved: Bool) -> [String] {
        let cleaned = reported.map { $0.lowercased() }
        let seen = Set(cleaned)
        var result = ladder.filter { seen.contains($0) }
        if includingReserved, seen.contains(reserved) { result.append(reserved) }
        var placed = Set(result)
        // Whether or not it survived above, `reserved` is never appended by the unknown path.
        placed.insert(reserved)
        for name in cleaned where !placed.contains(name) && isWellFormed(name) {
            result.append(name)
            placed.insert(name)
        }
        return Array(result.prefix(maximumReported))
    }

    /// True when this build cannot place the level on the cost ladder, so the UI must not imply one.
    static func isUnrecognized(_ name: String) -> Bool {
        let cleaned = name.lowercased()
        return cleaned != reserved && !ladder.contains(cleaned)
    }
}
