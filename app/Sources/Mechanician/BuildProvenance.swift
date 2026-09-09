import Foundation

/// The signed build record packaged in `Contents/Resources`. The dogfood bit is deliberately
/// separate from CFBundleVersion: public builds keep their normal release identity, while a local
/// candidate can still say exactly which source revision produced it.
struct BuildProvenance: Decodable, Equatable {
    let dogfood: Bool?
    /// The corpus tenant sealed into this bundle. This is build identity, not the active managed
    /// profile: the public bundle may load a signed external profile while retaining public Help.
    let tenantId: String?
    let sourceCommit: String?
    /// `git diff --binary HEAD` hashed at build time. Already recorded; it was simply never read,
    /// which is why two builds an edit apart were indistinguishable.
    let sourceDiffSHA256: String?
    /// Identity of the immutable Help authority sealed beside this record.
    let helpCorpusSchemaVersion: Int?
    let helpCorpusSHA256: String?

    static let current = load(from: .main)

    /// SHA-256 of nothing, which is what hashing an empty diff produces. A tree with no uncommitted
    /// change is therefore recognisable by a constant rather than by a flag nobody wrote.
    static let cleanTreeDiffDigest =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// True when the build was made from a working tree carrying uncommitted changes, so its commit
    /// alone does not describe the code inside it. Unknown digests count as modified: a build that
    /// cannot prove it was clean should not claim to be.
    var builtFromModifiedTree: Bool {
        guard let sourceDiffSHA256 else { return false }
        return sourceDiffSHA256.lowercased() != Self.cleanTreeDiffDigest
    }

    var dogfoodSourceStamp: String? {
        guard dogfood == true, let sourceCommit else { return nil }
        let normalized = sourceCommit.lowercased()
        guard normalized.count >= 7,
              normalized.unicodeScalars.allSatisfy({ scalar in
                  ("0"..."9").contains(Character(String(scalar)))
                      || ("a"..."f").contains(Character(String(scalar)))
              }) else { return nil }
        // The commit alone is not an identity for a local build. Building, editing, and building
        // again produces two different apps at one commit, which is exactly the case that sent us
        // diagnosing a bug that was already fixed.
        return "Dogfood \(normalized.prefix(7))\(builtFromModifiedTree ? " + local changes" : "")"
    }

    static func load(from bundle: Bundle) -> BuildProvenance? {
        guard let url = bundle.url(forResource: "BuildProvenance", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BuildProvenance.self, from: data)
    }
}

enum BuildVersionLabel {
    static func make(
        version: String,
        build: String,
        provenance: BuildProvenance? = BuildProvenance.current
    ) -> String {
        let releaseIdentity = "\(version) (\(build))"
        guard let stamp = provenance?.dogfoodSourceStamp else { return releaseIdentity }
        return "\(releaseIdentity) · \(stamp)"
    }
}
