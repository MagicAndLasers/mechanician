import Foundation

/// Finds existing absolute image paths embedded in the flattened composer/provider prompt.
/// Paths may contain spaces (notably `~/Library/Application Support/...`), so a conventional
/// whitespace-delimited regex is insufficient. Work backwards from each image extension and
/// accept the nearest slash-delimited candidate that actually exists on disk.
enum ImagePathDetector {
    struct Match: Equatable {
        let path: String
        let range: NSRange
    }

    static func matches(in text: String,
                        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:))
        -> [Match] {
        guard text.contains("/") else { return [] }
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        var matches: [Match] = []
        // Keep candidate work linear in prompt length. The old implementation rescanned the whole
        // line and compared against every prior match for every extension, which made a long prompt
        // containing repeated image paths quadratic on the MainActor.
        var scannedThrough = 0
        var slashLocations: [Int] = []
        let maximumSlashCandidates = 64
        imageExtensionRegex.enumerateMatches(in: text, range: fullRange) {
            endpoint, _, _ in
            guard let endpoint else { return }
            let end = NSMaxRange(endpoint.range)
            guard end > scannedThrough else { return }
            for index in scannedThrough..<end {
                switch ns.character(at: index) {
                case 10, 13: // LF / CR: an absolute path cannot cross a line boundary.
                    slashLocations.removeAll(keepingCapacity: true)
                case 47: // "/"
                    slashLocations.append(index)
                    if slashLocations.count > maximumSlashCandidates {
                        slashLocations.removeFirst(
                            slashLocations.count - maximumSlashCandidates)
                    }
                default:
                    break
                }
            }
            scannedThrough = end

            var accepted: Match?
            for start in slashLocations.reversed() {
                let range = NSRange(location: start, length: end - start)
                let candidate = ns.substring(with: range)
                if fileExists(candidate) {
                    accepted = Match(path: candidate, range: range)
                    break
                }
            }
            guard let accepted else { return }
            matches.append(accepted)
            // Later matches cannot overlap this accepted path. Dropping its component slashes also
            // bounds memory for a single very long line containing thousands of valid references.
            slashLocations.removeAll(keepingCapacity: true)
        }
        return matches
    }

    private static let imageExtensionRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\.(?:png|jpe?g|gif|webp|heic|heif|bmp|tiff?)"#,
            options: [.caseInsensitive])
    }()
}
