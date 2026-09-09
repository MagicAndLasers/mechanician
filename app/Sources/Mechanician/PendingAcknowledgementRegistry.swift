import Foundation

/// A bounded, exact correlation gate between something the app staged and the daemon's later proof
/// that it crossed the provider-specific tool-result boundary.
///
/// The value is intentionally generic: transport correlation does not need to know or copy what it
/// is correlating. `AgentBridge` keeps the payload private and releases it only when the exact
/// `(turnID, requestID)` is taken. A duplicate key, capacity pressure, unknown acknowledgement, or
/// late acknowledgement all fail closed.
///
/// Three of its four users are Help consultation receipts, workflow-advice receipts and
/// ShowMechanician acknowledgements. It was named for the fourth, which no longer exists.
struct PendingAcknowledgementRegistry<Value> {
    struct Key: Hashable {
        let turnID: String
        let requestID: String
    }

    private let limit: Int
    private var values: [Key: Value] = [:]

    init(limit: Int = 128) {
        self.limit = max(0, limit)
    }

    var count: Int { values.count }

    mutating func stage(_ value: Value, turnID: String, requestID: String) -> Bool {
        let key = Key(turnID: turnID, requestID: requestID)
        guard !turnID.isEmpty, !requestID.isEmpty,
              turnID.utf8.count <= 256, requestID.utf8.count <= 256,
              values[key] == nil, values.count < limit else { return false }
        values[key] = value
        return true
    }

    mutating func take(turnID: String, requestID: String) -> Value? {
        values.removeValue(forKey: Key(turnID: turnID, requestID: requestID))
    }

    /// Consume the exact pending value even when its echoed metadata is wrong. This makes a
    /// mismatch terminal and fail-closed: a later corrected-looking acknowledgement cannot reuse
    /// evidence the daemon already contradicted.
    mutating func take(
        turnID: String,
        requestID: String,
        matching predicate: (Value) -> Bool
    ) -> Value? {
        guard let value = take(turnID: turnID, requestID: requestID),
              predicate(value) else { return nil }
        return value
    }

    mutating func discard(turnID: String, requestID: String) {
        values[Key(turnID: turnID, requestID: requestID)] = nil
    }

    mutating func discard(turnID: String) {
        values = values.filter { $0.key.turnID != turnID }
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: false)
    }
}
