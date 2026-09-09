import Foundation

enum UserMessagePresentationSegment: Identifiable, Equatable {
    case text(Int, String)
    case image(Int, String)
    case artifact(Int, ArtifactDragReference)
    case file(Int, ConversationFileReference)

    var id: Int {
        switch self {
        case .text(let id, _), .image(let id, _), .artifact(let id, _), .file(let id, _):
            return id
        }
    }
}

/// Reconstruct the authored interleaving of text, pasted images, generic files, and artifact
/// references from the durable prompt. Provider-facing paths/tagged metadata stay in `text`; the
/// transcript replaces them at their authored positions with visual attachments.
func userMessagePresentationSegments(
    text: String,
    imagePaths: [String]?
) -> [UserMessagePresentationSegment] {
    enum Candidate {
        case image(String)
        case artifact(ArtifactDragReference)
        case file(ConversationFileReference)
    }
    struct PositionedCandidate {
        let range: NSRange
        let candidate: Candidate
    }

    let source = text as NSString
    let artifactMatches = ArtifactDragReference.matches(in: text)
    let fileMatches = ConversationFileReference.matches(in: text)
    let paths = imagePaths ?? []
    guard !paths.isEmpty || !artifactMatches.isEmpty || !fileMatches.isEmpty
    else { return [.text(0, text)] }

    var segments: [UserMessagePresentationSegment] = []
    var cursor = 0
    var nextID = 0

    while cursor < source.length {
        let searchRange = NSRange(location: cursor, length: source.length - cursor)
        var candidates = paths.compactMap { path -> PositionedCandidate? in
            let range = source.range(of: path, options: [], range: searchRange)
            guard range.location != NSNotFound else { return nil }
            return PositionedCandidate(range: range, candidate: .image(path))
        }
        candidates.append(contentsOf: artifactMatches.compactMap { match in
            guard match.range.location >= cursor else { return nil }
            return PositionedCandidate(
                range: match.range,
                candidate: .artifact(match.reference))
        })
        candidates.append(contentsOf: fileMatches.compactMap { match in
            guard match.range.location >= cursor else { return nil }
            return PositionedCandidate(
                range: match.range,
                candidate: .file(match.reference))
        })
        let positioned = candidates.min {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            // An artifact token may itself contain an image-like source path. Prefer replacing the
            // whole token rather than exposing fragments of its transport JSON.
            switch ($0.candidate, $1.candidate) {
            case (.artifact, .image): return true
            case (.image, .artifact): return false
            default: return $0.range.length > $1.range.length
            }
        }
        guard let positioned else {
            segments.append(.text(
                nextID,
                source.substring(with: NSRange(
                    location: cursor,
                    length: source.length - cursor))))
            break
        }

        if positioned.range.location > cursor {
            segments.append(.text(
                nextID,
                source.substring(with: NSRange(
                    location: cursor,
                    length: positioned.range.location - cursor))))
            nextID += 1
        }
        switch positioned.candidate {
        case .image(let path):
            segments.append(.image(nextID, path))
        case .artifact(let reference):
            segments.append(.artifact(nextID, reference))
        case .file(let reference):
            segments.append(.file(nextID, reference))
        }
        nextID += 1
        cursor = NSMaxRange(positioned.range)
    }
    return segments
}
