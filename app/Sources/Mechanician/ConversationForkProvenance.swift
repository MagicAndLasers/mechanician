import Foundation

/// Local provenance for a conversation created by branching retained history.
///
/// This deliberately records only durable record-local identities. Provider sessions, file-system
/// locations, and other machine-specific bindings are not lineage and must never leak into it.
struct ConversationForkProvenance: Codable, Equatable {
    /// A raw-value wrapper keeps a provenance record readable when a newer build introduces another
    /// fork kind. Callers can recognize the kinds they understand without quarantining the whole
    /// conversation merely because the discriminator is newer.
    struct Kind: RawRepresentable, Codable, Equatable, Hashable {
        let rawValue: String

        static let assistantResponse = Kind(rawValue: "assistantResponse")

        init(rawValue: String) {
            self.rawValue = rawValue
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            rawValue = try container.decode(String.self)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    let kind: Kind
    /// The source's current local conversation identity, not a portable lineage or file identity.
    let sourceConversationID: UUID
    /// Harmless presentation fallback retained when the local source is later unavailable.
    let sourceTitleSnapshot: String?
    /// The transcript entry selected as the branch point inside the source record.
    let forkPointEntryID: UUID
    let createdAt: Date

    /// Return a navigation target only while this installation still has the identified source.
    /// Availability is identity-based: a path, title, or timestamp must never make a source
    /// clickable because none of those values proves that it is the same conversation.
    func clickableSourceID(in availableConversationIDs: Set<UUID>) -> UUID? {
        availableConversationIDs.contains(sourceConversationID) ? sourceConversationID : nil
    }
}
