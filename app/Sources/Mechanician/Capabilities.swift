import Foundation

/// A **capability** is a working automation you *bless*: Claude runs an AppleScript/JXA live
/// (which already works through the permission gate), you say "save that", and it becomes a
/// named, parameterized, self-tested verb the agent (and later ambient/Siri) can invoke forever.
///
/// One unified object, backed by a mechanism (AppleScript/JXA first — no Shortcut-import
/// friction; the de-risk killed silent shortcut JIT). Stored one-JSON-per-file under
/// `<support>/capabilities/`, mirroring the artifact store, so the daemon can write back
/// verification/run-count and the app picks it up via a directory watcher.
struct Capability: Identifiable, Codable, Equatable {
    var uuid = UUID()
    var id: UUID { uuid }
    var name: String                 // invocation key, snake_case: "add_to_reminders"
    var title: String                // display: "Add to Reminders"
    var description: String          // what it does + WHEN to use — the line Claude sees in the catalog
    /// A sentence a person would actually say to invoke this, shown in the library so the panel can
    /// answer "how do I use it?". Optional because deriving one from `description` mostly works —
    /// but only mostly: descriptions are written for a model deciding WHETHER to call something,
    /// and several reduce to noise ("Use Read My Notes") or a bare fragment. When it matters,
    /// state it rather than hope the derivation lands.
    var examplePrompt: String? = nil
    var mechanism: Mechanism = .appleScript
    var target: Target? = nil        // the app it drives (for the icon + the TCC grant it needs)
    var params: [CapabilityParam] = []
    var backing = Backing()          // mechanism-specific payload
    var safety: Safety = .additive   // gates auto-allow + whether a self-test may run live
    var verification = Verification()
    var origin: String = "agent"     // agent | user | discovered
    var bornFrom: String? = nil      // conversation id (provenance)
    var enabled = true
    var runCount = 0
    var createdAt = Date()
    var updatedAt = Date()

    enum CodingKeys: String, CodingKey {
        case uuid = "id", name, title, description, examplePrompt, mechanism, target, params,
             backing, safety, verification, origin, bornFrom, enabled, runCount,
             createdAt, updatedAt
    }

    init(name: String, title: String, description: String, mechanism: Mechanism = .appleScript,
         target: Target? = nil, params: [CapabilityParam] = [], backing: Backing = Backing(),
         safety: Safety = .additive, origin: String = "agent", bornFrom: String? = nil) {
        self.name = name; self.title = title; self.description = description
        self.mechanism = mechanism; self.target = target; self.params = params
        self.backing = backing; self.safety = safety; self.origin = origin; self.bornFrom = bornFrom
    }

    // Tolerant decode — older/partial JSON (and daemon-written files) may omit newer keys.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        uuid = try c.decodeIfPresent(UUID.self, forKey: .uuid) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? name
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        examplePrompt = try c.decodeIfPresent(String.self, forKey: .examplePrompt)
        mechanism = try c.decodeIfPresent(Mechanism.self, forKey: .mechanism) ?? .appleScript
        target = try c.decodeIfPresent(Target.self, forKey: .target)
        params = try c.decodeIfPresent([CapabilityParam].self, forKey: .params) ?? []
        backing = try c.decodeIfPresent(Backing.self, forKey: .backing) ?? Backing()
        safety = try c.decodeIfPresent(Safety.self, forKey: .safety) ?? .additive
        verification = try c.decodeIfPresent(Verification.self, forKey: .verification) ?? Verification()
        origin = try c.decodeIfPresent(String.self, forKey: .origin) ?? "agent"
        bornFrom = try c.decodeIfPresent(String.self, forKey: .bornFrom)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        runCount = try c.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// One-line catalog entry inlined into the system prompt: `name(p1, p2?) — description [verified]`.
    var catalogLine: String {
        let sig = params.map { $0.name + ($0.optional ? "?" : "") }.joined(separator: ", ")
        let tag = verification.state == "passed" ? " [verified]"
            : verification.state == "failed" ? " [needs retest]" : ""
        return "\(name)(\(sig)) — \(description)\(tag)"
    }
}

enum Mechanism: String, Codable { case appleScript, shortcut, appIntent, computerUse }

/// How dangerous a capability is — gates whether "always allow" is offered and whether the
/// self-test may run for real. Destructive (send/delete) is never auto-allowed or silently tested.
enum Safety: String, Codable { case additive, read, destructive }

struct Target: Codable, Equatable { var appName: String; var bundleID: String? }

struct CapabilityParam: Codable, Equatable {
    var name: String
    var title: String = ""
    var type: String = "string"      // string | number | bool | date | enum | file
    var optional = false
    var enumValues: [String]? = nil
    var description: String = ""
}

/// Mechanism-specific payload, discriminated by `Capability.mechanism`.
struct Backing: Codable, Equatable {
    // appleScript: the script MUST read args from `argv` (`on run argv` / `function run(argv)`) —
    // args are passed as process arguments, NEVER interpolated into the source (injection-safe).
    var language: String? = nil      // "applescript" | "javascript"
    var script: String? = nil
    // shortcut (later): invoked by name/identifier with JSON args as the single --input-path.
    var shortcutName: String? = nil
    var shortcutIdentifier: String? = nil
}

struct Verification: Codable, Equatable {
    var state: String = "untested"   // untested | passed | failed
    var lastTestedAt: Date? = nil
    var lastError: String? = nil
    var sampleOutput: String? = nil
    /// Which TCC identity actually ran it (interactive app vs ambient/launchd) — health is never
    /// assumed global, per the TCC-attribution open question.
    var testedIdentity: String? = nil
}
