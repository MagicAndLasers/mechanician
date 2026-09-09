import Foundation

/// A configured `ISO8601DateFormatter` that can be shared across threads.
///
/// The stores encode and decode on background queues (`saveQueue`, the capability `io` queue) while
/// living on the main actor, and `JSONEncoder`/`JSONDecoder` date strategies are `@Sendable`
/// closures. A bare `ISO8601DateFormatter` can satisfy neither: it is not `Sendable`, and a
/// main-actor `static let` cannot be read from a background queue at all.
///
/// The two obvious escapes are both worse than this. `nonisolated(unsafe)` asserts safety without
/// providing any, resting on the undocumented thread-safety of `ISO8601DateFormatter` —
/// `DateFormatter` is documented safe when unmutated, but `ISO8601DateFormatter` makes no such
/// promise. Building a formatter inside the strategy closure instead allocates an ICU-backed
/// formatter *per date*, on exactly the large-conversation encode path the sidecar format exists to
/// keep fast.
///
/// So serialize instead. The formatter is configured once at init, never exposed, and every use is
/// taken under a lock, which makes the `@unchecked Sendable` conformance true by construction
/// rather than by assumption about Foundation's internals. An uncontended `NSLock` costs
/// nanoseconds against ICU formatting, and contention is near-zero: a save and a load rarely
/// overlap, and each holds the lock only for the call itself.
final class SendableISO8601Formatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    init(options: ISO8601DateFormatter.Options) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        self.formatter = formatter
    }

    /// The fractional-second form the daemon (Node) stamps.
    static let fractional = SendableISO8601Formatter(
        options: [.withInternetDateTime, .withFractionalSeconds])

    /// Plain `.withInternetDateTime`, which is what Foundation's own `.iso8601` strategy writes.
    static let plain = SendableISO8601Formatter(options: [.withInternetDateTime])

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: string)
    }
}

/// A main-actor box for a value that has to be read from inside the very closure that produces it.
///
/// The self-removing `NotificationCenter` observer needs its own token: the block is registered
/// first, and the token it returns is assigned afterwards. Capturing that `var` directly puts
/// shared mutable state across a `@Sendable` boundary — the write and the block's read are formally
/// unordered, which is what the compiler objects to, and `NSObjectProtocol` is not `Sendable`.
///
/// A `@MainActor` class is implicitly `Sendable` because the actor protects its storage, so the box
/// is safe to capture and the token is only ever touched on the main actor. That is already where
/// these handlers run — they are registered with `queue: .main` and immediately enter
/// `MainActor.assumeIsolated`.
@MainActor
final class MainActorBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
