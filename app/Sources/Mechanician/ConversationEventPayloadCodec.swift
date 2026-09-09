import Foundation

/// Transparent compression for the large conversation event payloads.
///
/// **Why.** `transcript.tool` is 972 MB of a 1,176 MB authority, 86% of it, because tool output is
/// file listings, code and build logs kept verbatim. Measured on 40 real payloads from a live
/// library, zlib returns 3.6x, so that 972 MB becomes roughly 272 MB. Nothing is deleted, nothing is
/// relocated, and nothing that exists today stops existing: this is the only lever on the authority
/// that costs no content at all.
///
/// **Why not `payload_version`.** The obvious move is to bump the version and call it an encoding.
/// That would be wrong, because `payload_version` is already a contract with live readers rather
/// than a free field. The launch delegate projection counts rows whose `payload_version != 1` and
/// refuses to launch on any hit, precisely so a malformed row fails closed rather than being
/// skipped; the same query then reads those payloads with `json_extract`. Writing version 2 rows
/// would turn that fail-closed check into a refusal on every ordinary row, and relaxing it to
/// accommodate an encoding would make it stop noticing the malformed ones — a correctness check
/// quietly doing nothing, which is the worst outcome available.
///
/// **So the encoding is self-describing instead.** A compressed payload carries its own header, and
/// `payload_version` keeps meaning exactly what it always meant. No schema change, no migration, and
/// old rows are not touched. Compression is applied lazily as rows are rewritten.
///
/// **Which kinds.** Only `transcript.tool`, deliberately. It is 86% of the bytes and it is the one
/// large kind that **no SQL statement introspects**: every site that reads inside a payload from
/// SQL is guarded to `legacy_projection.*`. Compressing those would break the launch delegate
/// projection. Growth of this set is a decision, not an accident, which is why it is a closed list
/// rather than a size heuristic.
enum ConversationEventPayloadCodec {

    /// `0x00` first, because no JSON document and no UTF-8 text begins with a null byte, so a
    /// stored payload written before this existed can never be mistaken for a compressed one.
    static let magic: [UInt8] = [0x00, 0x4D, 0x5A, 0x43]   // \0MZC

    /// 4 magic bytes plus a big-endian UInt32 of the original length.
    static let headerCount = 8

    /// Below this, the header plus deflate overhead is not worth the round trip, and small payloads
    /// are a rounding error in a store whose problem is megabyte tool outputs.
    static let minimumCompressibleBytes = 1_024

    /// The only kinds that may be compressed. See the type comment for why this is closed.
    static let compressibleKinds: Set<String> = ["transcript.tool"]

    static func isCompressible(kind: String) -> Bool { compressibleKinds.contains(kind) }

    /// Compress when it is allowed, worthwhile, and actually smaller. Otherwise return the input
    /// unchanged, so the common path costs one set lookup and one size comparison.
    static func encode(_ payload: Data, kind: String) -> Data {
        guard isCompressible(kind: kind),
              payload.count >= minimumCompressibleBytes,
              !hasHeader(payload),
              let deflated = try? (payload as NSData).compressed(using: .zlib) as Data,
              deflated.count + headerCount < payload.count
        else { return payload }

        var out = Data(capacity: deflated.count + headerCount)
        out.append(contentsOf: magic)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(deflated)
        return out
    }

    /// Return the original bytes for any payload, compressed or not.
    ///
    /// **Fails open to the input.** A payload that carries the header but does not inflate, or
    /// inflates to the wrong length, is returned untouched rather than throwing. A false positive
    /// would need arbitrary bytes to begin with the magic AND be valid deflate AND inflate to
    /// exactly the recorded length; returning the input in that case is still the safest answer,
    /// because a wrong decode would corrupt a transcript while a passthrough merely fails to shrink.
    static func decode(_ stored: Data) -> Data {
        guard hasHeader(stored), stored.count > headerCount else { return stored }
        let expected = stored[stored.startIndex + 4..<stored.startIndex + 8]
            .reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let body = stored[(stored.startIndex + headerCount)...]
        guard let inflated = try? (Data(body) as NSData).decompressed(using: .zlib) as Data,
              inflated.count == Int(expected)
        else { return stored }
        return inflated
    }

    static func hasHeader(_ data: Data) -> Bool {
        guard data.count >= headerCount else { return false }
        return Array(data[data.startIndex..<data.startIndex + 4]) == magic
    }
}
